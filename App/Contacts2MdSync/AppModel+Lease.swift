import Contacts2MdCLI
import Foundation
import SyncEngine

// The vault lease in the app (architecture §11, M6; docs/ui.md §9, §14):
// Take Over, Release Lease, Settings ▸ Advanced and the Overview's
// following line.

extension AppModel {
    /// Settings ▸ Advanced ▸ Sync lease: role, holder, heartbeat, other devices.
    var leaseInfo: UILeaseInfo? {
        data.map { UILeaseInfo(status: $0.status, live: live.leaseStatus, deviceID: $0.device.id) }
    }

    /// Overview: "Mac B leads; it still has N changes to apply" while another device leads.
    var follower: UIFollowerLine? {
        UIFollowerLine.current(live: live.isHosting ? live.state : nil, status: data?.status, reviewTotal: counts.total)
    }

    /// Release Lease (Settings ▸ Advanced): another device may lead at once.
    /// While live sync runs here, its next run takes the lease again unless
    /// another device does first.
    func releaseLease() async {
        guard let root = rootURL else { return }
        if live.isHosting {
            _ = await live.releaseLease()
        } else {
            do {
                _ = try await source.releaseLease(root: root)
            } catch {
                errorMessage = Self.describe(error)
            }
        }
        await reload()
    }
}
