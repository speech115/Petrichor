import Foundation
import PetrichorCore

extension ArtworkBytes {
    /// Wraps the Rust allocation without copying it; the deallocator keeps this object alive until the Data is released.
    var data: Data {
        // Rust boxed slices are never null; even an empty one has a dangling non-zero address.
        guard let bytes = UnsafeMutableRawPointer(bitPattern: UInt(address())) else { return Data() }
        return Data(
            bytesNoCopy: bytes,
            count: Int(length()),
            deallocator: .custom { _, _ in withExtendedLifetime(self) {} }
        )
    }
}
