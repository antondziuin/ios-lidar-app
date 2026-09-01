"""TCP viewer: RGB (OpenCV) + colored LiDAR point cloud (Open3D)."""

from __future__ import annotations

import argparse
import socket
import threading
import time

import cv2
import numpy as np
import open3d as o3d

from protocol import decode_frame, read_packet, unproject_point_cloud


def guess_local_ip() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def resize_for_display(image: np.ndarray, max_width: int = 960) -> np.ndarray:
    height, width = image.shape[:2]
    if width <= max_width:
        return image
    scale = max_width / width
    return cv2.resize(image, (max_width, int(height * scale)), interpolation=cv2.INTER_AREA)


class FrameBuffer:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._frame = None
        self._peer = "—"
        self._status = "ожидание телефона"
        self._frames = 0
        self._bytes = 0
        self._window_start = time.perf_counter()
        self._fps = 0.0
        self._kbps = 0.0

    def set_status(self, status: str, peer: str | None = None) -> None:
        with self._lock:
            self._status = status
            if peer is not None:
                self._peer = peer

    def push(self, frame, nbytes: int, peer: str) -> None:
        now = time.perf_counter()
        with self._lock:
            self._frame = frame
            self._peer = peer
            self._status = "стрим"
            self._frames += 1
            self._bytes += nbytes
            elapsed = now - self._window_start
            if elapsed >= 1.0:
                self._fps = self._frames / elapsed
                self._kbps = self._bytes / elapsed / 1024.0
                self._frames = 0
                self._bytes = 0
                self._window_start = now

    def snapshot(self):
        with self._lock:
            return self._frame, self._peer, self._status, self._fps, self._kbps


def accept_loop(host: str, port: int, buffer: FrameBuffer, stop: threading.Event) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(1)
    server.settimeout(0.5)
    print(f"Listening on {host}:{port}  (this PC IP: {guess_local_ip()})")

    try:
        while not stop.is_set():
            try:
                conn, addr = server.accept()
            except TimeoutError:
                continue
            except OSError:
                break

            peer = f"{addr[0]}:{addr[1]}"
            buffer.set_status("подключён", peer)
            print(f"Client connected: {peer}")
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.settimeout(1.0)
            try:
                while not stop.is_set():
                    try:
                        body = read_packet(conn)
                    except TimeoutError:
                        continue
                    frame = decode_frame(body)
                    buffer.push(frame, 4 + len(body), peer)
            except (ConnectionError, OSError, ValueError) as exc:
                print(f"Client disconnected: {peer} ({exc})")
                buffer.set_status("ожидание телефона", peer)
            finally:
                conn.close()
    finally:
        server.close()


def overlay_status(image: np.ndarray, text: str) -> np.ndarray:
    canvas = image.copy()
    cv2.putText(
        canvas,
        text,
        (16, 32),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (0, 255, 80),
        2,
        cv2.LINE_AA,
    )
    return canvas


def run_viewer(args: argparse.Namespace) -> None:
    buffer = FrameBuffer()
    stop = threading.Event()
    thread = threading.Thread(
        target=accept_loop,
        args=(args.host, args.port, buffer, stop),
        daemon=True,
    )
    thread.start()

    vis = o3d.visualization.Visualizer()
    vis.create_window(window_name="LiDAR Point Cloud", width=960, height=720)
    pcd = o3d.geometry.PointCloud()
    axes = o3d.geometry.TriangleMesh.create_coordinate_frame(size=0.25)
    vis.add_geometry(axes)
    cloud_added = False
    last_timestamp = None

    last_rgb = np.zeros((360, 640, 3), dtype=np.uint8)
    last_label = "starting"
    cv2.namedWindow("RGB", cv2.WINDOW_NORMAL)

    try:
        while True:
            frame, peer, status, fps, kbps = buffer.snapshot()
            if frame is not None and frame.timestamp != last_timestamp:
                last_timestamp = frame.timestamp
                rgb = cv2.imdecode(np.frombuffer(frame.jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
                if rgb is None:
                    continue
                points, colors = unproject_point_cloud(
                    frame.depth,
                    rgb,
                    frame.K,
                    frame.confidence,
                    stride=args.stride,
                    min_range=args.min_range,
                    max_range=args.max_range,
                    min_confidence=args.min_confidence,
                )
                count = int(points.shape[0])
                if points.shape[0] == 0:
                    points = np.zeros((1, 3), dtype=np.float64)
                    colors = np.zeros((1, 3), dtype=np.float64)
                pcd.points = o3d.utility.Vector3dVector(points)
                pcd.colors = o3d.utility.Vector3dVector(colors)
                if not cloud_added:
                    vis.add_geometry(pcd, reset_bounding_box=True)
                    cloud_added = True
                else:
                    vis.update_geometry(pcd)
                last_rgb = resize_for_display(rgb)
                last_label = f"{peer}  {status}  {fps:.1f} fps  {kbps:.0f} KB/s  n={count}"
            else:
                last_label = f"{peer}  {status}  {fps:.1f} fps  {kbps:.0f} KB/s"

            cv2.imshow("RGB", overlay_status(last_rgb, last_label))
            if not vis.poll_events():
                break
            vis.update_renderer()
            key = cv2.waitKey(1) & 0xFF
            if key in (27, ord("q")):
                break
    finally:
        stop.set()
        vis.destroy_window()
        cv2.destroyAllWindows()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Receive iPhone RGB + LiDAR and show a live point cloud")
    parser.add_argument("--host", default="0.0.0.0", help="bind address")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--stride", type=int, default=2, help="keep every Nth depth pixel")
    parser.add_argument("--min-range", type=float, default=0.1)
    parser.add_argument("--max-range", type=float, default=8.0)
    parser.add_argument("--min-confidence", type=int, default=1, help="0=low, 1=medium, 2=high")
    return parser.parse_args()


if __name__ == "__main__":
    run_viewer(parse_args())
