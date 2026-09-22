import SwiftUI

// Select the established property wrapper explicitly. The macOS 27 CLT SDK also
// exports a same-named @State macro whose implementation ships with full Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>
