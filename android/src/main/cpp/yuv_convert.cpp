#include "yuv_convert.h"

#include <cstring>

namespace fbvr {
namespace {

inline uint8_t clamp(int value) { return static_cast<uint8_t>(value < 0 ? 0 : (value > 255 ? 255 : value)); }

}  // namespace

bool plane_fits(const Plane& plane, int width, int height) {
  if (plane.data == nullptr || width <= 0 || height <= 0 || plane.row_stride <= 0 || plane.pixel_stride <= 0) {
    return false;
  }
  const size_t last = static_cast<size_t>(height - 1) * static_cast<size_t>(plane.row_stride) +
                      static_cast<size_t>(width - 1) * static_cast<size_t>(plane.pixel_stride);
  return last < plane.size;
}

bool yuv_to_rgba(const Plane& y, const Plane& u, const Plane& v, int width, int height, uint8_t* out) {
  const int chroma_width = (width + 1) / 2;
  const int chroma_height = (height + 1) / 2;
  if (out == nullptr || !plane_fits(y, width, height) || !plane_fits(u, chroma_width, chroma_height) ||
      !plane_fits(v, chroma_width, chroma_height)) {
    return false;
  }
  for (int row = 0; row < height; row++) {
    const uint8_t* y_row = y.data + static_cast<size_t>(row) * y.row_stride;
    const uint8_t* u_row = u.data + static_cast<size_t>(row >> 1) * u.row_stride;
    const uint8_t* v_row = v.data + static_cast<size_t>(row >> 1) * v.row_stride;
    uint8_t* out_row = out + static_cast<size_t>(row) * width * 4;
    for (int column = 0; column < width; column++) {
      const int luma = y_row[static_cast<size_t>(column) * y.pixel_stride];
      const int blue = static_cast<int>(u_row[static_cast<size_t>(column >> 1) * u.pixel_stride]) - 128;
      const int red = static_cast<int>(v_row[static_cast<size_t>(column >> 1) * v.pixel_stride]) - 128;
      // BT.601 full range, in fixed point (the factors are multiplied by 256).
      out_row[column * 4 + 0] = clamp(luma + ((359 * red) >> 8));
      out_row[column * 4 + 1] = clamp(luma - ((88 * blue + 183 * red) >> 8));
      out_row[column * 4 + 2] = clamp(luma + ((454 * blue) >> 8));
      out_row[column * 4 + 3] = 0xFF;
    }
  }
  return true;
}

bool yuv_to_nv21(const Plane& y, const Plane& u, const Plane& v, int width, int height, uint8_t* out) {
  const int chroma_width = (width + 1) / 2;
  const int chroma_height = (height + 1) / 2;
  if (out == nullptr || !plane_fits(y, width, height) || !plane_fits(u, chroma_width, chroma_height) ||
      !plane_fits(v, chroma_width, chroma_height)) {
    return false;
  }
  uint8_t* position = out;
  for (int row = 0; row < height; row++) {
    const uint8_t* y_row = y.data + static_cast<size_t>(row) * y.row_stride;
    if (y.pixel_stride == 1) {
      std::memcpy(position, y_row, static_cast<size_t>(width));
      position += width;
    } else {
      for (int column = 0; column < width; column++) *position++ = y_row[static_cast<size_t>(column) * y.pixel_stride];
    }
  }
  for (int row = 0; row < chroma_height; row++) {
    const uint8_t* u_row = u.data + static_cast<size_t>(row) * u.row_stride;
    const uint8_t* v_row = v.data + static_cast<size_t>(row) * v.row_stride;
    for (int column = 0; column < chroma_width; column++) {
      *position++ = v_row[static_cast<size_t>(column) * v.pixel_stride];
      *position++ = u_row[static_cast<size_t>(column) * u.pixel_stride];
    }
  }
  return true;
}

}  // namespace fbvr
