// LOCAL PATCH: DuoPC. Tells the client when a whole FramebufferUpdate has been decoded, so it can
// show the update in one go instead of drawing the framebuffer while rectangles are still arriving.

public protocol VNCConnectionFrameDelegate: AnyObject {
	/// Called on the connection's receive thread after every rectangle of an update has been decoded
	/// and reported through `connection(_:didUpdateFramebuffer:x:y:width:height:)`, before the next
	/// update is read. Work done here delays the next update, so keep it short.
	func connectionDidFinishFramebufferUpdate(_ connection: VNCConnection)
}
