defmodule EvercamMedia.Snapshot.DBHandler do
  @moduledoc """
  This module should ideally delegate all the updates to be made to the database
  on various events to another module.

  Right now, this is a extracted and slightly modified from the previous version of
  worker.

  These are the list of tasks for the db handler
    * Create an entry in the snapshots table for each retrived snapshots
    * Update the CameraActivity table whenever there is a change in the camera status
    * Update the status and last_polled_at values of Camera table
    * Update the thumbnail_url of the Camera table - This was done in the previous
    version and not now. This update can be avoided if thumbnails can be dynamically
    served.
  """
  use GenEvent
  require Logger
  alias EvercamMedia.Repo
  alias EvercamMedia.SnapshotRepo
  alias EvercamMedia.Util
  alias EvercamMedia.Snapshot.Error
  alias Calendar.DateTime
  alias Calendar.Strftime

  def handle_event({:got_snapshot, data}, state) do
    {camera_exid, timestamp, image} = data
    Logger.debug "[#{camera_exid}] [snapshot_success]"
    notes = "Evercam Proxy"
    camera = Camera.get_full("#{camera_exid}")
    spawn fn -> save_snapshot_record(camera, timestamp, nil, notes) end
    spawn fn -> update_camera_status("#{camera_exid}", timestamp, true) end
    ConCache.put(:cache, camera_exid, %{image: image, timestamp: timestamp, notes: notes})
    {:ok, state}
  end

  def handle_event({:snapshot_error, data}, state) do
    {camera_exid, timestamp, error} = data
    Error.parse(error)
    |> Error.handle_snapshot_error(camera_exid, timestamp, error)
    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  def calculate_motion_level(_camera_exid, _image_1, nil), do: nil
  def calculate_motion_level(camera_exid, image_1, %{image: image_2}) do
    try do
      EvercamMedia.MotionDetection.Lib.compare(camera_exid, image_1, image_2)
    rescue
      error ->
        Util.error_handler(error)
        nil
    end
  end

  def update_camera_status(camera_exid, timestamp, status, error_code \\ "generic", error_weight \\ 0) do
    do_update_camera_status(camera_exid, timestamp, status, error_code, error_weight)
  end

  defp do_update_camera_status("", _timestamp, _status, _error_code, _error_weight), do: :noop
  defp do_update_camera_status(camera_exid, timestamp, status, error_code, error_weight) do
    camera = Camera.get_full(camera_exid)
    old_error_total = ConCache.dirty_get_or_store(:snapshot_error, camera.exid, fn() -> 0 end)
    error_total = old_error_total + error_weight
    cond do
      status == true && camera.is_online != status ->
        change_camera_status(camera, timestamp, true)
        ConCache.dirty_put(:snapshot_error, camera.exid, 0)
        Logger.warn "[#{camera_exid}] [update_status] [online]"
      status == true ->
        ConCache.dirty_put(:snapshot_error, camera.exid, 0)
      status == false && camera.is_online != status && error_total >= 100 ->
        change_camera_status(camera, timestamp, false)
        Logger.warn "[#{camera_exid}] [update_status] [offline] [#{error_code}]"
      status == false && camera.is_online != status ->
        ConCache.dirty_put(:snapshot_error, camera.exid, error_total)
        Logger.warn "[#{camera_exid}] [update_status] [error] [#{error_code}] [#{error_total}]"
      status == false ->
        ConCache.dirty_put(:snapshot_error, camera.exid, error_total)
      true -> :noop
    end
    Camera.get_full(camera_exid)
  end

  def change_camera_status(camera, timestamp, status) do
    try do
      task = Task.async(fn() ->
        datetime =
          Calendar.DateTime.Parse.unix!(timestamp)
          |> Calendar.DateTime.to_erl
          |> Ecto.DateTime.cast!
        params = construct_camera(datetime, status, camera.is_online == status)
        changeset = Camera.changeset(camera, params)
        Repo.update!(changeset)
        ConCache.delete(:camera_full, camera.exid)
        invalidate_camera_cache(camera)
        broadcast_change_to_users(camera)
        log_camera_status(camera, status, datetime)
      end)
      Task.await(task, :timer.seconds(1))
    catch _type, error ->
      Util.error_handler(error)
    end
  end

  def invalidate_camera_cache(camera) do
    Exq.enqueue(Exq, "cache", "Evercam::CacheInvalidationWorker", camera.exid)
  end

  def broadcast_change_to_users(camera) do
    User.with_access_to(camera)
    |> Enum.each(fn(user) -> Util.broadcast_camera_status(camera.exid, camera.is_online, user.username) end)
  end

  def log_camera_status(camera, true, datetime) do
    parameters = %{camera_id: camera.id, action: "online", done_at: datetime}
    changeset = CameraActivity.changeset(%CameraActivity{}, parameters)
    SnapshotRepo.insert(changeset)
    if camera.is_online_email_owner_notification do
      EvercamMedia.UserMailer.camera_online(camera.owner, camera)
    end
  end

  def log_camera_status(camera, false, datetime) do
    parameters = %{camera_id: camera.id, action: "offline", done_at: datetime}
    changeset = CameraActivity.changeset(%CameraActivity{}, parameters)
    SnapshotRepo.insert(changeset)
    if camera.is_online_email_owner_notification do
      EvercamMedia.UserMailer.camera_offline(camera.owner, camera)
    end
  end

  def save_snapshot_record(camera, timestamp, motion_level, notes) do
    datetime =
      Calendar.DateTime.Parse.unix!(timestamp)
      |> Calendar.DateTime.to_erl
      |> Ecto.DateTime.cast!
    snapshot_timestamp =
      Calendar.DateTime.Parse.unix!(timestamp)
      |> Calendar.Strftime.strftime!("%Y%m%d%H%M%S%f")

    snapshot_id = Util.format_snapshot_id(camera.id, snapshot_timestamp)
    parameters = %{camera_id: camera.id, notes: notes, motionlevel: motion_level, created_at: datetime, snapshot_id: snapshot_id}
    changeset = Snapshot.changeset(%Snapshot{}, parameters)
    SnapshotRepo.insert(changeset)
  end

  def generate_thumbnail_url(camera_exid, timestamp) do
    iso_timestamp =
      timestamp
      |> DateTime.Parse.unix!
      |> Strftime.strftime!("%Y-%m-%dT%H:%M:%S.%f")
      |> String.slice(0, 23)
      |> String.ljust(23, ?0)
      |> String.ljust(24, ?Z)
    token = Util.encode([camera_exid, iso_timestamp])
    EvercamMedia.Endpoint.static_url <> "/v1/cameras/#{camera_exid}/thumbnail/#{iso_timestamp}?token=#{token}"
  end

  defp construct_camera(datetime, online_status, online_status_unchanged) do
    camera_params(datetime, online_status, online_status_unchanged)
  end

  defp camera_params(datetime, _, true) do
    %{updated_at: datetime, last_polled_at: datetime}
  end

  defp camera_params(datetime, false, false) do
    %{updated_at: datetime, last_polled_at: datetime, is_online: false}
  end

  defp camera_params(datetime, true, false) do
    %{updated_at: datetime, last_polled_at: datetime, is_online: true, last_online_at: datetime}
  end
end
