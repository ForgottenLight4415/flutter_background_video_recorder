#include "frame_ring.h"

#include <atomic>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace fbvr {
namespace {

struct Ring {
  RingId id = 0;
  int slot_count = 0;
  size_t capacity = 0;
  uint8_t* memory = nullptr;
  std::unique_ptr<std::atomic<int32_t>[]> refs;
  std::unique_ptr<std::atomic<bool>[]> dart_held;
  // One token for "the ring is open", one for every slot in use and one for every operation in
  // progress. The thread that brings it to zero frees the ring, so nothing is freed while in use.
  std::atomic<int32_t> tokens{1};
  std::atomic<bool> closed{false};
  std::atomic<int64_t> dropped{0};
};

std::mutex g_mutex;
std::unordered_map<RingId, Ring*> g_rings;
RingId g_next_id = 1;

void destroy(Ring* ring) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_rings.erase(ring->id);
  }
  std::free(ring->memory);
  delete ring;
}

void drop_token(Ring* ring) {
  if (ring->tokens.fetch_sub(1, std::memory_order_acq_rel) == 1) destroy(ring);
}

// Finds a ring and takes a token on it, atomically with respect to the ring being freed: a ring
// whose tokens reached zero is never revived.
Ring* pin(RingId id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_rings.find(id);
  if (it == g_rings.end()) return nullptr;
  Ring* ring = it->second;
  int32_t current = ring->tokens.load();
  while (current > 0) {
    if (ring->tokens.compare_exchange_weak(current, current + 1, std::memory_order_acq_rel)) return ring;
  }
  return nullptr;
}

// Holds a pinned ring for the duration of an operation.
class Pinned {
 public:
  explicit Pinned(RingId id) : ring_(pin(id)) {}
  ~Pinned() {
    if (ring_ != nullptr) drop_token(ring_);
  }
  Pinned(const Pinned&) = delete;
  Pinned& operator=(const Pinned&) = delete;
  Ring* get() const { return ring_; }
  Ring* operator->() const { return ring_; }
  explicit operator bool() const { return ring_ != nullptr; }
  bool has_slot(int slot) const { return ring_ != nullptr && slot >= 0 && slot < ring_->slot_count; }

 private:
  Ring* ring_;
};

void release_slot(Ring* ring, int slot) {
  if (ring->refs[slot].fetch_sub(1, std::memory_order_acq_rel) == 1) drop_token(ring);
}

}  // namespace

RingId ring_create(int slot_count, size_t capacity) {
  if (slot_count <= 0 || capacity == 0) return 0;
  // Slots start on a cache line, and never share one.
  const size_t aligned = (capacity + 63) & ~static_cast<size_t>(63);
  void* memory = nullptr;
  if (posix_memalign(&memory, 64, aligned * static_cast<size_t>(slot_count)) != 0) return 0;
  auto* ring = new Ring();
  ring->slot_count = slot_count;
  ring->capacity = aligned;
  ring->memory = static_cast<uint8_t*>(memory);
  ring->refs.reset(new std::atomic<int32_t>[slot_count]);
  ring->dart_held.reset(new std::atomic<bool>[slot_count]);
  for (int i = 0; i < slot_count; i++) {
    ring->refs[i].store(0);
    ring->dart_held[i].store(false);
  }
  std::lock_guard<std::mutex> lock(g_mutex);
  ring->id = g_next_id++;
  g_rings[ring->id] = ring;
  return ring->id;
}

int ring_acquire(RingId id) {
  Pinned ring(id);
  if (!ring || ring->closed.load()) return -1;
  for (int slot = 0; slot < ring->slot_count; slot++) {
    int32_t expected = 0;
    if (ring->refs[slot].compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) {
      // The slot's own token. The ring is pinned, so this cannot race with it being freed.
      ring->tokens.fetch_add(1, std::memory_order_acq_rel);
      return slot;
    }
  }
  ring->dropped.fetch_add(1);
  return -1;
}

uint8_t* ring_slot_data(RingId id, int slot) {
  Pinned ring(id);
  // The memory outlives this call as long as the caller holds a reference on the slot.
  return ring.has_slot(slot) ? ring->memory + static_cast<size_t>(slot) * ring->capacity : nullptr;
}

size_t ring_capacity(RingId id) {
  Pinned ring(id);
  return ring ? ring->capacity : 0;
}

void ring_retain_for_dart(RingId id, int slot) {
  Pinned ring(id);
  if (!ring.has_slot(slot)) return;
  ring->refs[slot].fetch_add(1, std::memory_order_acq_rel);
  ring->dart_held[slot].store(true);
}

void ring_release(RingId id, int slot) {
  Pinned ring(id);
  if (!ring.has_slot(slot)) return;
  release_slot(ring.get(), slot);
}

void ring_release_by_dart(RingId id, int slot) {
  Pinned ring(id);
  if (!ring.has_slot(slot)) return;
  if (ring->dart_held[slot].exchange(false)) release_slot(ring.get(), slot);
}

void ring_abandon_all_dart() {
  std::vector<RingId> ids;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (const auto& entry : g_rings) ids.push_back(entry.first);
  }
  for (RingId id : ids) {
    Pinned ring(id);
    if (!ring) continue;
    for (int slot = 0; slot < ring->slot_count; slot++) {
      if (ring->dart_held[slot].exchange(false)) release_slot(ring.get(), slot);
    }
  }
}

void ring_close(RingId id) {
  Pinned ring(id);
  if (!ring) return;
  if (ring->closed.exchange(true)) return;
  // The "open" token.
  drop_token(ring.get());
}

int64_t ring_dropped(RingId id) {
  Pinned ring(id);
  return ring ? ring->dropped.load() : -1;
}

int ring_live_count() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return static_cast<int>(g_rings.size());
}

}  // namespace fbvr

extern "C" void fbvr_slot_release(int64_t ring_id, int32_t slot) { fbvr::ring_release_by_dart(ring_id, slot); }
