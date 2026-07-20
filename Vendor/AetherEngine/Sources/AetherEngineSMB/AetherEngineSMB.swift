// AetherEngineSMB: opt-in SMB2/3 byte source for AetherEngine.
// Transport is kishikawakatsumi/SMBClient (pure-Swift, MIT, NWConnection-based),
// linked only by consumers that link the AetherEngineSMB product; it never
// enters the core engine binary.

/// Marker for the AetherEngineSMB module version surface.
public enum AetherEngineSMB {
    public static let isAvailable = true
}
