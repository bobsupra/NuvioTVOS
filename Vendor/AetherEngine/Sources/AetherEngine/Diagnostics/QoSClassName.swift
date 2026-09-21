import Darwin

/// One name for a QoS class. Both self-retuning producers report theirs (AE#286 the HLS pump,
/// AE#519 the software read-ahead), and both read the class BACK after setting it: a thread that was
/// opted out of the QoS system keeps the old one silently, and then the whole mechanism is a no-op
/// that still looks configured.
enum QoSClass {
    static func name(_ c: qos_class_t) -> String {
        switch c {
        case QOS_CLASS_USER_INTERACTIVE: return "userInteractive"
        case QOS_CLASS_USER_INITIATED: return "userInitiated"
        case QOS_CLASS_DEFAULT: return "default"
        case QOS_CLASS_UTILITY: return "utility"
        case QOS_CLASS_BACKGROUND: return "background"
        default: return "unspecified"
        }
    }
}
