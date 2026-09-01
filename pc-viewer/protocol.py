"""LiDAR streamer binary protocol (shared with the iOS FrameCodec).

Each TCP message is: uint32 big-endian body length, then the body.

Body layout (big-endian, no padding), HEADER_SIZE = 138 bytes:

    magic           4s      "LIDR"
    version         B       1
    flags           B       bit 0 = confidence map present
    timestamp       d       ARKit frame timestamp, seconds
    rgb_w, rgb_h    HH      JPEG pixel size (intrinsics match this)
    depth_w, depth_h HH     depth / confidence pixel size
    jpeg_size       I
    depth_size      I       raw-deflate (COMPRESSION_ZLIB) of Float32 LE, row-major metres
    confidence_size I       uncompressed UInt8, 0 if absent
    reserved        I       0
    K               9f      row-major 3x3 camera intrinsics for the JPEG
    T               16f     column-major 4x4 camera-to-world (ARKit simd layout)
    jpeg bytes
    deflate depth bytes
    confidence bytes (optional)

Depth payload is Apple Compression COMPRESSION_ZLIB: raw DEFLATE, not zlib/gzip wrapped.
"""

from __future__ import annotations

import socket
import struct
import zlib
from dataclasses import dataclass

import numpy as np

MAGIC = b"LIDR"
VERSION = 1
FLAG_CONFIDENCE = 1 << 0

HEADER_STRUCT = struct.Struct(">4sBBdHHHHIIII9f16f")
HEADER_SIZE = HEADER_STRUCT.size
assert HEADER_SIZE == 138

_LENGTH = struct.Struct(">I")


@dataclass
class Frame:
    timestamp: float
    rgb_w: int
    rgb_h: int
    depth_w: int
    depth_h: int
    K: np.ndarray
    T: np.ndarray
    jpeg: bytes
    depth: np.ndarray
    confidence: np.ndarray | None


def deflate(data: bytes, level: int = 6) -> bytes:
    compressor = zlib.compressobj(level, zlib.DEFLATED, wbits=-15)
    return compressor.compress(data) + compressor.flush()


def inflate(data: bytes) -> bytes:
    decompressor = zlib.decompressobj(wbits=-15)
    return decompressor.decompress(data) + decompressor.flush()


def encode_frame(
    timestamp: float,
    jpeg: bytes,
    depth: np.ndarray,
    K: np.ndarray,
    T: np.ndarray,
    confidence: np.ndarray | None = None,
) -> bytes:
    if depth.dtype != np.float32 or depth.ndim != 2:
        raise ValueError("depth must be float32 with shape (H, W)")
    depth_h, depth_w = depth.shape
    rgb_w, rgb_h = _jpeg_size_or_raise(jpeg)
    depth_bytes = deflate(np.ascontiguousarray(depth).tobytes())
    flags = 0
    conf_bytes = b""
    if confidence is not None:
        if confidence.shape != depth.shape or confidence.dtype != np.uint8:
            raise ValueError("confidence must be uint8 with the same shape as depth")
        flags |= FLAG_CONFIDENCE
        conf_bytes = np.ascontiguousarray(confidence).tobytes()

    k_vals = np.asarray(K, dtype=np.float32).reshape(3, 3).ravel(order="C")
    t_vals = np.asarray(T, dtype=np.float32).flatten(order="F")
    header = HEADER_STRUCT.pack(
        MAGIC,
        VERSION,
        flags,
        float(timestamp),
        int(rgb_w),
        int(rgb_h),
        int(depth_w),
        int(depth_h),
        len(jpeg),
        len(depth_bytes),
        len(conf_bytes),
        0,
        *k_vals.tolist(),
        *t_vals.tolist(),
    )
    return header + jpeg + depth_bytes + conf_bytes


def decode_frame(body: bytes) -> Frame:
    if len(body) < HEADER_SIZE:
        raise ValueError(f"body too short: {len(body)} < {HEADER_SIZE}")
    unpacked = HEADER_STRUCT.unpack(body[:HEADER_SIZE])
    magic = unpacked[0]
    version = unpacked[1]
    flags = unpacked[2]
    timestamp = unpacked[3]
    rgb_w, rgb_h, depth_w, depth_h = unpacked[4:8]
    jpeg_size, depth_size, conf_size, _reserved = unpacked[8:12]
    k_vals = unpacked[12:21]
    t_vals = unpacked[21:37]

    if magic != MAGIC:
        raise ValueError(f"bad magic: {magic!r}")
    if version != VERSION:
        raise ValueError(f"unsupported version: {version}")

    expected = HEADER_SIZE + jpeg_size + depth_size + conf_size
    if len(body) != expected:
        raise ValueError(f"body size {len(body)} != expected {expected}")

    offset = HEADER_SIZE
    jpeg = body[offset : offset + jpeg_size]
    offset += jpeg_size
    depth_raw = inflate(body[offset : offset + depth_size])
    offset += depth_size
    expected_depth = depth_w * depth_h * 4
    if len(depth_raw) != expected_depth:
        raise ValueError(f"decompressed depth {len(depth_raw)} != {expected_depth}")
    depth = np.frombuffer(depth_raw, dtype="<f4").reshape((depth_h, depth_w)).copy()

    confidence = None
    has_conf = bool(flags & FLAG_CONFIDENCE)
    if has_conf:
        if conf_size != depth_w * depth_h:
            raise ValueError("confidence size does not match depth resolution")
        confidence = (
            np.frombuffer(body[offset : offset + conf_size], dtype=np.uint8)
            .reshape((depth_h, depth_w))
            .copy()
        )
    elif conf_size != 0:
        raise ValueError("confidence size set without FLAG_CONFIDENCE")

    K = np.asarray(k_vals, dtype=np.float32).reshape(3, 3)
    T = np.asarray(t_vals, dtype=np.float32).reshape((4, 4), order="F")
    return Frame(
        timestamp=timestamp,
        rgb_w=rgb_w,
        rgb_h=rgb_h,
        depth_w=depth_w,
        depth_h=depth_h,
        K=K,
        T=T,
        jpeg=jpeg,
        depth=depth,
        confidence=confidence,
    )


def wrap_packet(body: bytes) -> bytes:
    return _LENGTH.pack(len(body)) + body


def recv_exact(sock: socket.socket, nbytes: int) -> bytes:
    buf = bytearray()
    while len(buf) < nbytes:
        chunk = sock.recv(nbytes - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf.extend(chunk)
    return bytes(buf)


def read_packet(sock: socket.socket, max_body: int = 16 * 1024 * 1024) -> bytes:
    (length,) = _LENGTH.unpack(recv_exact(sock, 4))
    if length == 0 or length > max_body:
        raise ValueError(f"invalid frame length: {length}")
    return recv_exact(sock, length)


def unproject_point_cloud(
    depth: np.ndarray,
    rgb_bgr: np.ndarray,
    K: np.ndarray,
    confidence: np.ndarray | None = None,
    stride: int = 2,
    min_range: float = 0.1,
    max_range: float = 8.0,
    min_confidence: int = 1,
) -> tuple[np.ndarray, np.ndarray]:
    """Camera-space XYZ (Y up, Z forward) and RGB in 0..1 from a depth map + BGR image."""
    depth_h, depth_w = depth.shape
    rgb_h, rgb_w = rgb_bgr.shape[:2]
    fx = float(K[0, 0])
    fy = float(K[1, 1])
    cx = float(K[0, 2])
    cy = float(K[1, 2])
    sx = rgb_w / depth_w
    sy = rgb_h / depth_h

    us = np.arange(0, depth_w, stride, dtype=np.int32)
    vs = np.arange(0, depth_h, stride, dtype=np.int32)
    uu, vv = np.meshgrid(us, vs)
    z = depth[vv, uu]
    valid = np.isfinite(z) & (z > min_range) & (z < max_range)
    if confidence is not None:
        valid &= confidence[vv, uu] >= min_confidence
    uu = uu[valid]
    vv = vv[valid]
    z = z[valid].astype(np.float64)
    if z.size == 0:
        return np.zeros((0, 3), dtype=np.float64), np.zeros((0, 3), dtype=np.float64)

    u_rgb = uu.astype(np.float64) * sx
    v_rgb = vv.astype(np.float64) * sy
    x = (u_rgb - cx) / fx * z
    y = -(v_rgb - cy) / fy * z
    points = np.stack((x, y, z), axis=1)

    ui = np.clip(np.rint(u_rgb).astype(np.int32), 0, rgb_w - 1)
    vi = np.clip(np.rint(v_rgb).astype(np.int32), 0, rgb_h - 1)
    bgr = rgb_bgr[vi, ui].astype(np.float64) / 255.0
    colors = bgr[:, ::-1]
    return points, colors


def _jpeg_size_or_raise(jpeg: bytes) -> tuple[int, int]:
    import cv2

    image = cv2.imdecode(np.frombuffer(jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("invalid JPEG payload")
    h, w = image.shape[:2]
    return w, h
