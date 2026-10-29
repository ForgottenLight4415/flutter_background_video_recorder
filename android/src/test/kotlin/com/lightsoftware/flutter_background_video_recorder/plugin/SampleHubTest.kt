package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SampleHubTest {
    /** Stands in for the main thread: work waits until [runAll]. */
    private class FakeMainThread {
        val queue = ArrayDeque<() -> Unit>()
        val post: (() -> Unit) -> Unit = { queue.addLast(it) }

        fun runAll() {
            while (queue.isNotEmpty()) queue.removeFirst()()
        }
    }

    private class Recorder : SampleHub.Subscriber<Int> {
        val events = mutableListOf<String>()
        override fun onData(item: Int) {
            events += "data:$item"
        }

        override fun onError(code: String, message: String) {
            events += "error:$code"
        }

        override fun onClosed() {
            events += "closed"
        }
    }

    @Test
    fun everySubscriberGetsEveryItemInOrder() {
        val main = FakeMainThread()
        val hub = SampleHub<Int>(maxPending = 5, post = main.post)
        val first = Recorder()
        val second = Recorder()
        hub.addSubscriber(first)
        hub.addSubscriber(second)
        hub.publish(1)
        hub.publish(2)
        main.runAll()
        assertEquals(listOf("data:1", "data:2"), first.events)
        assertEquals(listOf("data:1", "data:2"), second.events)
    }

    @Test
    fun aRemovedSubscriberStopsReceivingWhileTheOtherCarriesOn() {
        val main = FakeMainThread()
        val hub = SampleHub<Int>(maxPending = 5, post = main.post)
        val staying = Recorder()
        val leaving = Recorder()
        hub.addSubscriber(staying)
        hub.addSubscriber(leaving)
        hub.publish(1)
        main.runAll()
        hub.removeSubscriber(leaving)
        hub.publish(2)
        main.runAll()
        assertEquals(listOf("data:1", "data:2"), staying.events)
        assertEquals(listOf("data:1"), leaving.events)
    }

    @Test
    fun nothingIsAcceptedWithoutSubscribers() {
        val main = FakeMainThread()
        val hub = SampleHub<Int>(maxPending = 5, post = main.post)
        assertFalse(hub.hasSubscribers)
        assertFalse(hub.canAccept)
        assertFalse(hub.publish(1))
        assertTrue(main.queue.isEmpty())
    }

    @Test
    fun itemsBeyondTheLimitAreDroppedUntilTheMainThreadCatchesUp() {
        val main = FakeMainThread()
        val hub = SampleHub<Int>(maxPending = 2, post = main.post)
        val recorder = Recorder()
        hub.addSubscriber(recorder)
        assertTrue(hub.publish(1))
        assertTrue(hub.publish(2))
        assertFalse(hub.canAccept)
        assertFalse(hub.publish(3))
        main.runAll()
        assertEquals(listOf("data:1", "data:2"), recorder.events)
        assertTrue(hub.canAccept)
        assertTrue(hub.publish(4))
    }

    @Test
    fun errorsAndClosingArriveAfterTheDataBeforeThem() {
        val main = FakeMainThread()
        val hub = SampleHub<Int>(maxPending = 5, post = main.post)
        val recorder = Recorder()
        hub.addSubscriber(recorder)
        hub.publish(1)
        hub.publishError("camera_disconnected", "gone")
        hub.publishClosed()
        main.runAll()
        assertEquals(listOf("data:1", "error:camera_disconnected", "closed"), recorder.events)
    }

    @Test
    fun addingTheSameSubscriberTwiceDeliversOnce() {
        val main = FakeMainThread()
        val hub = SampleHub<Int>(maxPending = 5, post = main.post)
        val recorder = Recorder()
        hub.addSubscriber(recorder)
        hub.addSubscriber(recorder)
        hub.publish(1)
        main.runAll()
        assertEquals(listOf("data:1"), recorder.events)
    }

    // region Dispatch hook

    @Test
    fun theHookRunsOnceAfterEverySubscriberSawTheItem() {
        val main = FakeMainThread()
        val order = mutableListOf<String>()
        val hub = SampleHub<Int>(maxPending = 5, post = main.post, onDispatched = { order += "dispatched:$it" })
        hub.addSubscriber(
            object : SampleHub.Subscriber<Int> {
                override fun onData(item: Int) {
                    order += "first:$item"
                }

                override fun onError(code: String, message: String) = Unit

                override fun onClosed() = Unit
            },
        )
        hub.addSubscriber(
            object : SampleHub.Subscriber<Int> {
                override fun onData(item: Int) {
                    order += "second:$item"
                }

                override fun onError(code: String, message: String) = Unit

                override fun onClosed() = Unit
            },
        )
        hub.publish(7)
        assertTrue(order.isEmpty())
        main.runAll()
        assertEquals(listOf("first:7", "second:7", "dispatched:7"), order)
    }

    @Test
    fun theHookRunsEvenWhenASubscriberFails() {
        val main = FakeMainThread()
        var dispatched = 0
        val hub = SampleHub<Int>(maxPending = 5, post = main.post, onDispatched = { dispatched++ })
        hub.addSubscriber(
            object : SampleHub.Subscriber<Int> {
                override fun onData(item: Int) = throw IllegalStateException("boom")

                override fun onError(code: String, message: String) = Unit

                override fun onClosed() = Unit
            },
        )
        hub.publish(1)
        try {
            main.runAll()
        } catch (_: IllegalStateException) {
        }
        assertEquals(1, dispatched)
    }

    @Test
    fun anItemTheHubRefusesIsLeftToTheCaller() {
        val main = FakeMainThread()
        val dispatched = mutableListOf<Int>()
        val hub = SampleHub<Int>(maxPending = 1, post = main.post, onDispatched = { dispatched += it })
        // Nobody listens: refused, and the hook does not run for it.
        assertFalse(hub.publish(1))
        hub.addSubscriber(Recorder())
        assertTrue(hub.publish(2))
        // Full: refused.
        assertFalse(hub.publish(3))
        main.runAll()
        assertEquals(listOf(2), dispatched)
    }

    private class CountingOwner : SlotOwner {
        var references = 1 // the producer's
        var dartReferences = 0

        override fun retainForDart(ring: Long, slot: Int) {
            references++
            dartReferences++
        }

        override fun release(ring: Long, slot: Int) {
            references--
        }
    }

    @Test
    fun aFramesSlotIsReleasedByTheHubAndKeptForDart() {
        val main = FakeMainThread()
        val owner = CountingOwner()
        val lease = FrameLease(owner, ring = 1, slot = 0, address = 0)
        val frame = RawFrameData(RawFrameFormat.YUV420, 4, 2, 0, 0, lease, emptyList(), 0)
        val hub = SampleHub<RawFrameData>(maxPending = 1, post = main.post, onDispatched = { it.lease.release() })
        hub.addSubscriber(
            object : SampleHub.Subscriber<RawFrameData> {
                // What the channel forwarder does: take a reference for Dart.
                override fun onData(item: RawFrameData) = item.lease.retainForDart()

                override fun onError(code: String, message: String) = Unit

                override fun onClosed() = Unit
            },
        )
        assertTrue(hub.publish(frame))
        main.runAll()
        // The producer's reference is gone; Dart's remains until it releases through dart:ffi.
        assertEquals(1, owner.references)
        assertEquals(1, owner.dartReferences)
    }

    @Test
    fun aFrameNobodyKeptIsFullyReleased() {
        val main = FakeMainThread()
        val owner = CountingOwner()
        val frame = RawFrameData(
            RawFrameFormat.YUV420, 4, 2, 0, 0, FrameLease(owner, 1, 0, 0), emptyList(), 0,
        )
        val hub = SampleHub<RawFrameData>(maxPending = 1, post = main.post, onDispatched = { it.lease.release() })
        hub.addSubscriber(
            object : SampleHub.Subscriber<RawFrameData> {
                override fun onData(item: RawFrameData) = Unit

                override fun onError(code: String, message: String) = Unit

                override fun onClosed() = Unit
            },
        )
        hub.publish(frame)
        main.runAll()
        assertEquals(0, owner.references)
    }

    // endregion

    // region SessionHolder

    private fun holder(main: FakeMainThread) = SessionHolder<Int, String>(SampleHub(maxPending = 5, post = main.post))

    @Test
    fun aSessionOpensAndTheCallerIsToldOnce() {
        val holder = holder(FakeMainThread())
        val outcomes = mutableListOf<OpenResult<String>>()
        holder.begin { outcomes += it }
        assertEquals(SessionHolder.State.STARTING, holder.state)
        assertTrue(holder.isOpen)
        holder.opened("info")
        holder.opened("again")
        assertEquals(SessionHolder.State.ACTIVE, holder.state)
        assertEquals(listOf<OpenResult<String>>(OpenResult.Opened("info")), outcomes)
    }

    @Test
    fun aFailureBeforeOpeningGoesToTheCallerNotTheSubscribers() {
        val main = FakeMainThread()
        val holder = holder(main)
        val subscriber = Recorder()
        holder.hub.addSubscriber(subscriber)
        val outcomes = mutableListOf<OpenResult<String>>()
        holder.begin { outcomes += it }
        holder.failed("camera_not_found", "none")
        main.runAll()
        assertEquals(listOf<OpenResult<String>>(OpenResult.Failed("camera_not_found", "none")), outcomes)
        assertTrue(subscriber.events.isEmpty())
        assertEquals(SessionHolder.State.IDLE, holder.state)
    }

    @Test
    fun aFailureAfterOpeningGoesToTheSubscribersAndEndsTheSession() {
        val main = FakeMainThread()
        val holder = holder(main)
        val subscriber = Recorder()
        holder.hub.addSubscriber(subscriber)
        holder.begin { }
        holder.opened("info")
        holder.failed("camera_disconnected", "lost")
        main.runAll()
        assertEquals(listOf("error:camera_disconnected", "closed"), subscriber.events)
        assertFalse(holder.isOpen)
    }

    @Test
    fun closingAnActiveSessionTellsTheSubscribersOnce() {
        val main = FakeMainThread()
        val holder = holder(main)
        val subscriber = Recorder()
        holder.hub.addSubscriber(subscriber)
        holder.begin { }
        holder.opened("info")
        holder.closed()
        holder.closed()
        main.runAll()
        assertEquals(listOf("closed"), subscriber.events)
    }

    @Test
    fun closingWhileStartingCancelsTheOpen() {
        val holder = holder(FakeMainThread())
        val outcomes = mutableListOf<OpenResult<String>>()
        holder.begin { outcomes += it }
        holder.closed()
        assertEquals(1, outcomes.size)
        assertTrue(outcomes.single() is OpenResult.Failed)
        assertFalse(holder.isOpen)
    }

    @Test
    fun aSessionCanOpenAgainAfterItEnded() {
        val holder = holder(FakeMainThread())
        holder.begin { }
        holder.opened("one")
        holder.closed()
        holder.begin { }
        holder.opened("two")
        assertEquals(SessionHolder.State.ACTIVE, holder.state)
    }

    // endregion
}
