// Host test of the frame ring and the pixel conversions. Plain asserts, no framework:
//   scripts/test_native.sh
#include <atomic>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include "../frame_ring.h"
#include "../yuv_convert.h"

using namespace fbvr;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(condition)                                                  \
  do {                                                                    \
    g_checks++;                                                           \
    if (!(condition)) {                                                   \
      g_failures++;                                                       \
      std::printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    }                                                                     \
  } while (0)

static void test_acquire_until_full_counts_drops() {
  RingId ring = ring_create(3, 100);
  CHECK(ring != 0);
  CHECK(ring_acquire(ring) == 0);
  CHECK(ring_acquire(ring) == 1);
  CHECK(ring_acquire(ring) == 2);
  CHECK(ring_dropped(ring) == 0);
  CHECK(ring_acquire(ring) == -1);
  CHECK(ring_acquire(ring) == -1);
  CHECK(ring_dropped(ring) == 2);
  ring_release(ring, 1);
  CHECK(ring_acquire(ring) == 1);
  ring_release(ring, 0);
  ring_release(ring, 1);
  ring_release(ring, 2);
  ring_close(ring);
}

static void test_slots_are_aligned_distinct_and_writable() {
  RingId ring = ring_create(4, 1000);
  const size_t capacity = ring_capacity(ring);
  CHECK(capacity >= 1000 && capacity % 64 == 0);
  uint8_t* previous = nullptr;
  for (int slot = 0; slot < 4; slot++) {
    uint8_t* data = ring_slot_data(ring, slot);
    CHECK(data != nullptr);
    CHECK(reinterpret_cast<uintptr_t>(data) % 64 == 0);
    if (previous != nullptr) CHECK(data == previous + capacity);
    std::memset(data, slot + 1, capacity);
    previous = data;
  }
  // Writing a slot does not disturb its neighbours.
  CHECK(ring_slot_data(ring, 0)[capacity - 1] == 1);
  CHECK(ring_slot_data(ring, 3)[0] == 4);
  CHECK(ring_slot_data(ring, 4) == nullptr);
  CHECK(ring_slot_data(ring, -1) == nullptr);
  ring_close(ring);
}

static void test_a_ring_is_freed_when_closed_and_idle() {
  const int before = ring_live_count();
  RingId ring = ring_create(2, 64);
  CHECK(ring_live_count() == before + 1);
  ring_close(ring);
  CHECK(ring_live_count() == before);
  // Everything after that is ignored.
  CHECK(ring_acquire(ring) == -1);
  CHECK(ring_slot_data(ring, 0) == nullptr);
  ring_release(ring, 0);
  ring_release_by_dart(ring, 0);
  ring_close(ring);
}

static void test_a_slot_in_use_keeps_the_ring_alive_after_close() {
  const int before = ring_live_count();
  RingId ring = ring_create(2, 64);
  int slot = ring_acquire(ring);
  uint8_t* data = ring_slot_data(ring, slot);
  std::memset(data, 0x5A, 64);
  ring_close(ring);
  CHECK(ring_live_count() == before + 1);
  CHECK(data[10] == 0x5A);
  // No new slot after close.
  CHECK(ring_acquire(ring) == -1);
  ring_release(ring, slot);
  CHECK(ring_live_count() == before);
}

static void test_dart_holds_a_slot_until_it_releases() {
  const int before = ring_live_count();
  RingId ring = ring_create(1, 64);
  int slot = ring_acquire(ring);
  CHECK(slot == 0);
  ring_retain_for_dart(ring, slot);  // refs: producer + Dart
  ring_release(ring, slot);          // the hub is done
  CHECK(ring_acquire(ring) == -1);   // Dart still holds it
  fbvr_slot_release(ring, slot);     // what dart:ffi calls
  int again = ring_acquire(ring);
  CHECK(again == 0);
  ring_release(ring, again);
  ring_close(ring);
  CHECK(ring_live_count() == before);
}

static void test_releasing_twice_by_dart_is_ignored() {
  RingId ring = ring_create(2, 64);
  int a = ring_acquire(ring);
  int b = ring_acquire(ring);
  ring_retain_for_dart(ring, a);
  ring_release(ring, a);
  ring_release_by_dart(ring, a);
  ring_release_by_dart(ring, a);  // must not free someone else's reference
  CHECK(ring_acquire(ring) == a);  // a is free, and b is still held
  ring_release(ring, a);
  ring_release(ring, b);
  ring_close(ring);
}

static void test_a_slot_dart_does_not_hold_cannot_be_released_by_dart() {
  RingId ring = ring_create(1, 64);
  int slot = ring_acquire(ring);
  ring_release_by_dart(ring, slot);  // the producer still owns it
  CHECK(ring_acquire(ring) == -1);
  ring_release(ring, slot);
  ring_close(ring);
}

static void test_abandoning_releases_what_dart_held() {
  const int before = ring_live_count();
  RingId ring = ring_create(3, 64);
  for (int i = 0; i < 3; i++) {
    int slot = ring_acquire(ring);
    ring_retain_for_dart(ring, slot);
    ring_release(ring, slot);
  }
  CHECK(ring_acquire(ring) == -1);
  ring_close(ring);
  CHECK(ring_live_count() == before + 1);  // Dart still holds all three
  ring_abandon_all_dart();
  CHECK(ring_live_count() == before);
}

static void test_a_slot_held_by_both_the_hub_and_dart_needs_both_releases() {
  RingId ring = ring_create(1, 64);
  int slot = ring_acquire(ring);  // the producer's reference, handed to the hub
  ring_retain_for_dart(ring, slot);
  ring_release(ring, slot);  // the hub is done
  CHECK(ring_acquire(ring) == -1);
  ring_release_by_dart(ring, slot);
  CHECK(ring_acquire(ring) == slot);
  ring_release(ring, slot);
  ring_close(ring);
}

static void test_invalid_arguments() {
  CHECK(ring_create(0, 64) == 0);
  CHECK(ring_create(2, 0) == 0);
  CHECK(ring_acquire(0) == -1);
  CHECK(ring_acquire(987654) == -1);
  CHECK(ring_dropped(987654) == -1);
  CHECK(ring_capacity(987654) == 0);
  ring_release(987654, 0);
  fbvr_slot_release(987654, 0);
}

// A producer fills slots with a pattern and hands them to a consumer standing in for Dart, which
// checks the pattern before releasing. Any slot reuse before release would show as corruption.
static void test_producer_and_consumer_threads() {
  const int before = ring_live_count();
  const size_t size = 4096;
  RingId ring = ring_create(4, size);
  std::mutex mutex;
  std::deque<std::pair<int, uint8_t>> queue;
  std::atomic<bool> done{false};
  std::atomic<int> corrupted{0};
  std::atomic<int> consumed{0};

  std::thread consumer([&] {
    for (;;) {
      std::pair<int, uint8_t> item;
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (queue.empty()) {
          if (done.load()) return;
          continue;
        }
        item = queue.front();
        queue.pop_front();
      }
      const uint8_t* data = ring_slot_data(ring, item.first);
      for (size_t i = 0; i < size; i += 61) {
        if (data[i] != item.second) {
          corrupted++;
          break;
        }
      }
      consumed++;
      fbvr_slot_release(ring, item.first);
    }
  });

  int produced = 0;
  for (int frame = 0; frame < 20000; frame++) {
    int slot = ring_acquire(ring);
    if (slot < 0) continue;
    const uint8_t pattern = static_cast<uint8_t>(frame % 251 + 1);
    std::memset(ring_slot_data(ring, slot), pattern, size);
    ring_retain_for_dart(ring, slot);
    ring_release(ring, slot);  // the hub's reference
    {
      std::lock_guard<std::mutex> lock(mutex);
      queue.emplace_back(slot, pattern);
    }
    produced++;
  }
  done = true;
  consumer.join();
  CHECK(corrupted.load() == 0);
  CHECK(consumed.load() == produced);
  CHECK(produced > 0);
  ring_close(ring);
  CHECK(ring_live_count() == before);
}

// region Conversions

static Plane plane(const std::vector<uint8_t>& bytes, int row_stride, int pixel_stride) {
  return Plane{bytes.data(), row_stride, pixel_stride, bytes.size()};
}

static void test_nv21_interleaves_v_before_u() {
  std::vector<uint8_t> y = {10, 20, 30, 40}, u = {100}, v = {200};
  uint8_t out[6];
  CHECK(yuv_to_nv21(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  const uint8_t expected[] = {10, 20, 30, 40, 200, 100};
  CHECK(std::memcmp(out, expected, 6) == 0);
}

static void test_nv21_skips_row_padding() {
  std::vector<uint8_t> y = {1, 2, 99, 99, 3, 4, 99, 99}, u = {5}, v = {6};
  uint8_t out[6];
  CHECK(yuv_to_nv21(plane(y, 4, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  const uint8_t expected[] = {1, 2, 3, 4, 6, 5};
  CHECK(std::memcmp(out, expected, 6) == 0);
}

static void test_nv21_reads_interleaved_chroma() {
  // U and V as views of interleaved buffers (pixel stride 2).
  std::vector<uint8_t> y = {1, 2, 3, 4}, u = {50, 60}, v = {70, 80};
  uint8_t out[6];
  CHECK(yuv_to_nv21(plane(y, 2, 1), plane(u, 2, 2), plane(v, 2, 2), 2, 2, out));
  const uint8_t expected[] = {1, 2, 3, 4, 70, 50};
  CHECK(std::memcmp(out, expected, 6) == 0);
}

static void test_nv21_of_a_wide_picture() {
  std::vector<uint8_t> y = {1, 2, 3, 4, 5, 6, 7, 8}, u = {11, 12}, v = {21, 22};
  uint8_t out[12];
  CHECK(yuv_to_nv21(plane(y, 4, 1), plane(u, 2, 1), plane(v, 2, 1), 4, 2, out));
  const uint8_t expected[] = {1, 2, 3, 4, 5, 6, 7, 8, 21, 11, 22, 12};
  CHECK(std::memcmp(out, expected, 12) == 0);
}

static void test_rgba_of_grey_keeps_luma() {
  std::vector<uint8_t> y = {0, 128, 255, 64}, u = {128}, v = {128};
  uint8_t out[16];
  CHECK(yuv_to_rgba(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  const int luma[] = {0, 128, 255, 64};
  for (int pixel = 0; pixel < 4; pixel++) {
    CHECK(out[pixel * 4 + 0] == luma[pixel]);
    CHECK(out[pixel * 4 + 1] == luma[pixel]);
    CHECK(out[pixel * 4 + 2] == luma[pixel]);
    CHECK(out[pixel * 4 + 3] == 255);
  }
}

static void test_rgba_of_high_v_is_red() {
  std::vector<uint8_t> y = {128, 128, 128, 128}, u = {128}, v = {255};
  uint8_t out[16];
  CHECK(yuv_to_rgba(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  CHECK(out[0] > 200);
  CHECK(out[1] < 100);
  CHECK(out[2] == 128);
}

static void test_rgba_clamps() {
  std::vector<uint8_t> y = {255, 255, 0, 0}, u = {255}, v = {255};
  uint8_t out[16];
  CHECK(yuv_to_rgba(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  CHECK(out[0] == 255);
  CHECK(out[2] == 255);
  CHECK(out[2 * 4 + 1] == 0);
}

static void test_a_plane_that_is_too_small_writes_nothing() {
  std::vector<uint8_t> y = {1, 2, 3}, u = {1}, v = {1};  // 2 x 2 needs 4 luma bytes
  uint8_t out[16];
  std::memset(out, 0xEE, sizeof(out));
  CHECK(!yuv_to_rgba(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  CHECK(!yuv_to_nv21(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  CHECK(out[0] == 0xEE && out[15] == 0xEE);
  CHECK(!yuv_to_rgba(plane(y, 2, 1), plane(u, 1, 1), plane(v, 1, 1), 0, 2, out));
  CHECK(!yuv_to_rgba(Plane{nullptr, 2, 1, 4}, plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
  CHECK(!yuv_to_rgba(plane(y, 0, 1), plane(u, 1, 1), plane(v, 1, 1), 2, 2, out));
}

// endregion

int main() {
  test_acquire_until_full_counts_drops();
  test_slots_are_aligned_distinct_and_writable();
  test_a_ring_is_freed_when_closed_and_idle();
  test_a_slot_in_use_keeps_the_ring_alive_after_close();
  test_dart_holds_a_slot_until_it_releases();
  test_releasing_twice_by_dart_is_ignored();
  test_a_slot_dart_does_not_hold_cannot_be_released_by_dart();
  test_abandoning_releases_what_dart_held();
  test_a_slot_held_by_both_the_hub_and_dart_needs_both_releases();
  test_invalid_arguments();
  test_producer_and_consumer_threads();
  test_nv21_interleaves_v_before_u();
  test_nv21_skips_row_padding();
  test_nv21_reads_interleaved_chroma();
  test_nv21_of_a_wide_picture();
  test_rgba_of_grey_keeps_luma();
  test_rgba_of_high_v_is_red();
  test_rgba_clamps();
  test_a_plane_that_is_too_small_writes_nothing();
  std::printf("%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
