#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// LOCAL PATCH: was an unlocked struct. Input calls enqueue on the caller's thread while the
// send Task dequeues on the cooperative pool, so access is now serialised with a lock.
final class Queue<T>: @unchecked Sendable {
	private var list = [T]()
	private let lock = NSLock()

	func enqueue(_ element: T) {
		lock.lock(); defer { lock.unlock() }
		list.append(element)
	}

	func dequeue() -> T? {
		lock.lock(); defer { lock.unlock() }
		guard !list.isEmpty else { return nil }
		return list.removeFirst()
	}

	func clear() {
		lock.lock(); defer { lock.unlock() }
		list.removeAll()
	}

	func peek() -> T? {
		lock.lock(); defer { lock.unlock() }
		return list.first
	}

	var isEmpty: Bool {
		lock.lock(); defer { lock.unlock() }
		return list.isEmpty
	}
}
