import Network

struct PeerInfo: Identifiable, Equatable {
    let id: String          // deviceID from TXT record
    let name: String
    let platform: String    // "mac" | "android"
    let endpoint: NWEndpoint

    static func == (lhs: PeerInfo, rhs: PeerInfo) -> Bool {
        lhs.id == rhs.id
    }
}
