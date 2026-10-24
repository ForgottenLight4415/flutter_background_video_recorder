package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderNameTest {
    @Test
    fun keepsPlainAndNestedNames() {
        assertEquals("My Videos", sanitizeFolderName("My Videos"))
        assertEquals("A/B", sanitizeFolderName("A/B"))
    }

    @Test
    fun dropsTraversalAndInvalidCharacters() {
        assertEquals("a/b", sanitizeFolderName("../a/./b/.."))
        assertEquals("ab", sanitizeFolderName("a*b?"))
    }

    @Test
    fun fallsBackToDefaultWhenEmpty() {
        assertEquals("Recordings", sanitizeFolderName(null))
        assertEquals("Recordings", sanitizeFolderName("  //.. "))
    }
}

class CoordinatesTest {
    @Test
    fun acceptsRealPositions() {
        org.junit.Assert.assertTrue(isValidCoordinates(37.42, -122.08))
        org.junit.Assert.assertTrue(isValidCoordinates(-90.0, 180.0))
    }

    @Test
    fun rejectsOutOfRangeAndNaN() {
        org.junit.Assert.assertFalse(isValidCoordinates(90.1, 0.0))
        org.junit.Assert.assertFalse(isValidCoordinates(0.0, -180.1))
        org.junit.Assert.assertFalse(isValidCoordinates(Double.NaN, 0.0))
    }
}
