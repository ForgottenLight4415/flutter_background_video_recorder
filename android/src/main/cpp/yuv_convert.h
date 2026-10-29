// Conversions of the camera's YUV 4:2:0 planes. Plain functions on pointers, tested on the host.
#pragma once

#include <cstddef>
#include <cstdint>

namespace fbvr {

struct Plane {
  const uint8_t* data;
  int row_stride;
  int pixel_stride;
  // The number of bytes available at |data|, to check that a picture fits before reading it.
  size_t size;
};

// True when a picture of |width| x |height| samples can be read from the plane.
bool plane_fits(const Plane& plane, int width, int height);

// Four bytes per pixel (red, green, blue, opaque alpha), rows packed without padding. |out| must
// have room for width * height * 4 bytes. Returns false, writing nothing, if the planes are too
// small for the picture.
bool yuv_to_rgba(const Plane& y, const Plane& u, const Plane& v, int width, int height, uint8_t* out);

// NV21: the Y plane followed by interleaved V and U samples at half the size. |out| must have room
// for width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2) bytes.
bool yuv_to_nv21(const Plane& y, const Plane& u, const Plane& v, int width, int height, uint8_t* out);

}  // namespace fbvr
