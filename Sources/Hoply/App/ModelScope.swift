import SwiftUI

struct ModelScope<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(model.shown)
    }
}
