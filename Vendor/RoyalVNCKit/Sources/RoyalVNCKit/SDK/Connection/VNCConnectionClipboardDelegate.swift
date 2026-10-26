// LOCAL PATCH: public clipboard API (upstream's is internal and UIKit-on-background-thread).
public protocol VNCConnectionClipboardDelegate: AnyObject {
	/// Called on a background thread when the server's clipboard changes (Latin-1 text).
	func connection(_ connection: VNCConnection, didReceiveClipboardText text: String)
}

public extension VNCConnection {
	/// Sends `text` as the server's clipboard (ClientCutText, Latin-1).
	func sendClipboardText(_ text: String) {
		enqueueClientCutTextMessage(text)
	}
}
