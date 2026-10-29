// The functions Kotlin calls (see FrameRingJni.kt), registered by name in JNI_OnLoad so that the
// exported symbol names do not have to match the package name.
#include <jni.h>

#include <cstring>

#include "frame_ring.h"
#include "yuv_convert.h"

namespace {

using fbvr::Plane;
using fbvr::RingId;

constexpr const char* kClass = "com/lightsoftware/flutter_background_video_recorder/plugin/FrameRingJni";

// Where in a slot to write, checked against the slot's size.
struct Target {
  uint8_t* data = nullptr;
};

bool target(RingId ring, jint slot, jint offset, size_t length, Target* out) {
  if (offset < 0) return false;
  const size_t capacity = fbvr::ring_capacity(ring);
  uint8_t* data = fbvr::ring_slot_data(ring, slot);
  if (data == nullptr || static_cast<size_t>(offset) + length > capacity) return false;
  out->data = data + offset;
  return true;
}

bool plane_of(JNIEnv* env, jobject buffer, jint row_stride, jint pixel_stride, Plane* plane) {
  if (buffer == nullptr) return false;
  void* address = env->GetDirectBufferAddress(buffer);
  const jlong size = env->GetDirectBufferCapacity(buffer);
  if (address == nullptr || size < 0) return false;
  *plane = Plane{static_cast<const uint8_t*>(address), row_stride, pixel_stride, static_cast<size_t>(size)};
  return true;
}

jlong NativeCreate(JNIEnv*, jclass, jint slots, jlong capacity) {
  if (capacity <= 0) return 0;
  return fbvr::ring_create(slots, static_cast<size_t>(capacity));
}

jint NativeAcquire(JNIEnv*, jclass, jlong ring) { return fbvr::ring_acquire(ring); }

jlong NativeSlotAddress(JNIEnv*, jclass, jlong ring, jint slot) {
  return reinterpret_cast<jlong>(fbvr::ring_slot_data(ring, slot));
}

jboolean NativeCopyBuffer(JNIEnv* env, jclass, jlong ring, jint slot, jint dst_offset, jobject src, jint src_offset,
                          jint length) {
  if (src == nullptr || src_offset < 0 || length < 0) return JNI_FALSE;
  void* address = env->GetDirectBufferAddress(src);
  const jlong capacity = env->GetDirectBufferCapacity(src);
  if (address == nullptr || capacity < 0 || static_cast<jlong>(src_offset) + length > capacity) return JNI_FALSE;
  Target to;
  if (!target(ring, slot, dst_offset, static_cast<size_t>(length), &to)) return JNI_FALSE;
  std::memcpy(to.data, static_cast<const uint8_t*>(address) + src_offset, static_cast<size_t>(length));
  return JNI_TRUE;
}

jboolean NativeCopyBytes(JNIEnv* env, jclass, jlong ring, jint slot, jint dst_offset, jbyteArray src, jint length) {
  if (src == nullptr || length < 0 || length > env->GetArrayLength(src)) return JNI_FALSE;
  Target to;
  if (!target(ring, slot, dst_offset, static_cast<size_t>(length), &to)) return JNI_FALSE;
  env->GetByteArrayRegion(src, 0, length, reinterpret_cast<jbyte*>(to.data));
  return env->ExceptionCheck() ? JNI_FALSE : JNI_TRUE;
}

jboolean NativeYuvToRgba(JNIEnv* env, jclass, jlong ring, jint slot, jint dst_offset, jobject y, jint y_row,
                         jint y_pixel, jobject u, jint u_row, jint u_pixel, jobject v, jint v_row, jint v_pixel,
                         jint width, jint height) {
  if (width <= 0 || height <= 0) return JNI_FALSE;
  Plane py, pu, pv;
  if (!plane_of(env, y, y_row, y_pixel, &py) || !plane_of(env, u, u_row, u_pixel, &pu) ||
      !plane_of(env, v, v_row, v_pixel, &pv)) {
    return JNI_FALSE;
  }
  Target to;
  if (!target(ring, slot, dst_offset, static_cast<size_t>(width) * height * 4, &to)) return JNI_FALSE;
  return fbvr::yuv_to_rgba(py, pu, pv, width, height, to.data) ? JNI_TRUE : JNI_FALSE;
}

jboolean NativeYuvToNv21(JNIEnv* env, jclass, jobject y, jint y_row, jint y_pixel, jobject u, jint u_row, jint u_pixel,
                         jobject v, jint v_row, jint v_pixel, jint width, jint height, jbyteArray out) {
  if (width <= 0 || height <= 0 || out == nullptr) return JNI_FALSE;
  const size_t needed = static_cast<size_t>(width) * height + 2 * static_cast<size_t>((width + 1) / 2) * ((height + 1) / 2);
  if (static_cast<size_t>(env->GetArrayLength(out)) < needed) return JNI_FALSE;
  Plane py, pu, pv;
  if (!plane_of(env, y, y_row, y_pixel, &py) || !plane_of(env, u, u_row, u_pixel, &pu) ||
      !plane_of(env, v, v_row, v_pixel, &pv)) {
    return JNI_FALSE;
  }
  jbyte* array = static_cast<jbyte*>(env->GetPrimitiveArrayCritical(out, nullptr));
  if (array == nullptr) return JNI_FALSE;
  const bool ok = fbvr::yuv_to_nv21(py, pu, pv, width, height, reinterpret_cast<uint8_t*>(array));
  env->ReleasePrimitiveArrayCritical(out, array, 0);
  return ok ? JNI_TRUE : JNI_FALSE;
}

void NativeRetainForDart(JNIEnv*, jclass, jlong ring, jint slot) { fbvr::ring_retain_for_dart(ring, slot); }
void NativeRelease(JNIEnv*, jclass, jlong ring, jint slot) { fbvr::ring_release(ring, slot); }
void NativeAbandonAllDart(JNIEnv*, jclass) { fbvr::ring_abandon_all_dart(); }
void NativeClose(JNIEnv*, jclass, jlong ring) { fbvr::ring_close(ring); }
jlong NativeDropped(JNIEnv*, jclass, jlong ring) { return fbvr::ring_dropped(ring); }
jint NativeLiveRings(JNIEnv*, jclass) { return fbvr::ring_live_count(); }

const JNINativeMethod kMethods[] = {
    {"nativeCreate", "(IJ)J", reinterpret_cast<void*>(NativeCreate)},
    {"nativeAcquire", "(J)I", reinterpret_cast<void*>(NativeAcquire)},
    {"nativeSlotAddress", "(JI)J", reinterpret_cast<void*>(NativeSlotAddress)},
    {"nativeCopyBuffer", "(JIILjava/nio/ByteBuffer;II)Z", reinterpret_cast<void*>(NativeCopyBuffer)},
    {"nativeCopyBytes", "(JII[BI)Z", reinterpret_cast<void*>(NativeCopyBytes)},
    {"nativeYuvToRgba", "(JIILjava/nio/ByteBuffer;IILjava/nio/ByteBuffer;IILjava/nio/ByteBuffer;IIII)Z",
     reinterpret_cast<void*>(NativeYuvToRgba)},
    {"nativeYuvToNv21", "(Ljava/nio/ByteBuffer;IILjava/nio/ByteBuffer;IILjava/nio/ByteBuffer;IIII[B)Z",
     reinterpret_cast<void*>(NativeYuvToNv21)},
    {"nativeRetainForDart", "(JI)V", reinterpret_cast<void*>(NativeRetainForDart)},
    {"nativeRelease", "(JI)V", reinterpret_cast<void*>(NativeRelease)},
    {"nativeAbandonAllDart", "()V", reinterpret_cast<void*>(NativeAbandonAllDart)},
    {"nativeClose", "(J)V", reinterpret_cast<void*>(NativeClose)},
    {"nativeDropped", "(J)J", reinterpret_cast<void*>(NativeDropped)},
    {"nativeLiveRings", "()I", reinterpret_cast<void*>(NativeLiveRings)},
};

}  // namespace

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  jclass type = env->FindClass(kClass);
  if (type == nullptr) return JNI_ERR;
  if (env->RegisterNatives(type, kMethods, static_cast<jint>(sizeof(kMethods) / sizeof(kMethods[0]))) != JNI_OK) {
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}
