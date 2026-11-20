import Foundation
import os

/// App-wide loggers. Rule: log events, states, codes and timings only, never transcripts, model
/// replies, audio, image data or window titles. Interpolate only values that are safe to see in
/// Console.app; anything derived from user content must not be logged at all.
public enum Log {
    public static let subsystem = "com.zakvirani.wisp"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let models = Logger(subsystem: subsystem, category: "models")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let vision = Logger(subsystem: subsystem, category: "vision")
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")
    public static let timing = Logger(subsystem: subsystem, category: "timing")
}
