import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.iconName)
            .accessibilityLabel(model.accessibilityStatus)
    }
}
