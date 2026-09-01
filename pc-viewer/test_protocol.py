"""Round-trip test for the LiDAR streamer binary protocol."""

from __future__ import annotations

import numpy as np
import cv2

from protocol import (
    FLAG_CONFIDENCE,
    HEADER_SIZE,
    HEADER_STRUCT,
    MAGIC,
    VERSION,
    decode_frame,
    deflate,
    encode_frame,
    inflate,
    read_packet,
    unproject_point_cloud,
    wrap_packet,
)


def _make_jpeg(width: int, height: int, color_bgr: tuple[int, int, int]) -> bytes:
    image = np.zeros((height, width, 3), dtype=np.uint8)
    image[:] = color_bgr
    image[height // 2, width // 2] = (0, 0, 255)  # red center in BGR
    ok, buf = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 90])
    assert ok, "JPEG encode failed"
    return buf.tobytes()


def test_deflate_roundtrip() -> None:
    payload = np.arange(256, dtype=np.float32).tobytes()
    restored = inflate(deflate(payload))
    assert restored == payload


def test_frame_roundtrip() -> None:
    rgb_w, rgb_h = 64, 48
    depth_w, depth_h = 32, 24
    jpeg = _make_jpeg(rgb_w, rgb_h, (32, 64, 128))
    depth = np.zeros((depth_h, depth_w), dtype=np.float32)
    depth[:, :] = 2.0
    depth[depth_h // 2, depth_w // 2] = 1.5
    confidence = np.full((depth_h, depth_w), 2, dtype=np.uint8)
    confidence[0, 0] = 0
    fx, fy = 40.0, 40.0
    cx, cy = rgb_w / 2.0, rgb_h / 2.0
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float32)
    T = np.eye(4, dtype=np.float32)
    T[0, 3] = 1.25

    body = encode_frame(
        timestamp=12.5,
        jpeg=jpeg,
        depth=depth,
        K=K,
        T=T,
        confidence=confidence,
    )
    packet = wrap_packet(body)
    assert int.from_bytes(packet[:4], "big") == len(body)
    assert body[:4] == MAGIC
    assert body[4] == VERSION
    assert body[5] & FLAG_CONFIDENCE
    assert len(body) > HEADER_SIZE

    frame = decode_frame(body)
    assert abs(frame.timestamp - 12.5) < 1e-9
    assert (frame.rgb_w, frame.rgb_h) == (rgb_w, rgb_h)
    assert (frame.depth_w, frame.depth_h) == (depth_w, depth_h)
    assert np.allclose(frame.K, K)
    assert np.allclose(frame.T, T)
    assert abs(frame.T[0, 3] - 1.25) < 1e-6
    packed = HEADER_STRUCT.unpack(body[:HEADER_SIZE])
    t_vals = packed[21:37]
    assert abs(t_vals[12] - 1.25) < 1e-6  # column-major: column 3, row 0
    assert np.allclose(frame.depth, depth, atol=1e-6)
    assert frame.confidence is not None
    assert np.array_equal(frame.confidence, confidence)

    rgb = cv2.imdecode(np.frombuffer(frame.jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
    assert rgb is not None
    points, colors = unproject_point_cloud(
        frame.depth, rgb, frame.K, frame.confidence, stride=1, min_confidence=1
    )
    assert points.shape[0] == depth.size - 1  # one low-confidence pixel dropped
    center = points[
        np.argmin(
            np.abs(points[:, 2] - 1.5)
            + np.abs(points[:, 0])
            + np.abs(points[:, 1])
        )
    ]
    assert abs(center[2] - 1.5) < 1e-3
    assert colors.shape == points.shape


def test_tcp_read_packet() -> None:
    import socket
    import threading

    jpeg = _make_jpeg(32, 24, (8, 16, 24))
    depth = np.full((12, 16), 3.25, dtype=np.float32)
    K = np.array([[10, 0, 16], [0, 10, 12], [0, 0, 1]], dtype=np.float32)
    T = np.eye(4, dtype=np.float32)
    body = encode_frame(1.0, jpeg, depth, K, T)
    packet = wrap_packet(body)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    errors: list[BaseException] = []

    def serve() -> None:
        try:
            conn, _ = server.accept()
            with conn:
                conn.sendall(packet)
        except BaseException as exc:
            errors.append(exc)
        finally:
            server.close()

    threading.Thread(target=serve, daemon=True).start()
    client = socket.create_connection(("127.0.0.1", port), timeout=2)
    with client:
        received = read_packet(client)
    assert not errors
    frame = decode_frame(received)
    assert np.allclose(frame.depth, depth)


if __name__ == "__main__":
    test_deflate_roundtrip()
    test_frame_roundtrip()
    test_tcp_read_packet()
    print("protocol tests passed")
