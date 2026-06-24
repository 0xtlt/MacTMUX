import SwiftUI

@MainActor
final class AppPresentationStore: ObservableObject {
    @Published private(set) var isMenuBarMenuPresented = false

    func setMenuBarMenuPresented(_ isPresented: Bool) {
        isMenuBarMenuPresented = isPresented
    }
}
