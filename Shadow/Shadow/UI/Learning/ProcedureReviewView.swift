import SwiftUI

/// Review panel showing a synthesized procedure before saving.
///
/// Displays the procedure name, description, steps with action icons,
/// parameters, and Save/Cancel buttons. The user can edit the name before saving.
struct ProcedureReviewView: View {
    let template: ProcedureTemplate
    let onSave: (ProcedureTemplate) -> Void
    let onCancel: () -> Void

    @State private var editedName: String

    init(
        template: ProcedureTemplate,
        onSave: @escaping (ProcedureTemplate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.template = template
        self.onSave = onSave
        self.onCancel = onCancel
        self._editedName = State(initialValue: template.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Steps list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(template.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index, step: step)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 300)

            // Parameters section
            if !template.parameters.isEmpty {
                Divider()
                parametersSection
                    .padding(16)
            }

            Divider()

            // Action bar
            actionBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 480)
        .background(.ultraThickMaterial)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 18))
                    .foregroundStyle(.purple)

                Text("Review Procedure")
                    .font(.system(size: 15, weight: .semibold))
            }

            TextField("Procedure Name", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))

            if !template.description.isEmpty {
                Text(template.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Step Row

    private func stepRow(index: Int, step: ProcedureStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Step number
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            // Action icon
            Image(systemName: iconForAction(step.actionType))
                .font(.system(size: 12))
                .foregroundStyle(colorForAction(step.actionType))
                .frame(width: 16)

            // Step description
            VStack(alignment: .leading, spacing: 2) {
                Text(step.intent)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                Text(describeAction(step.actionType))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Parameters

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parameters")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(template.parameters, id: \.name) { param in
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)

                    Text(param.name)
                        .font(.system(size: 12, weight: .medium))

                    Text(param.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if let defaultVal = param.defaultValue {
                        Text(defaultVal)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Text("\(template.steps.count) steps")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if !template.tags.isEmpty {
                Text(template.tags.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: {
                var saved = template
                saved.name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if saved.name.isEmpty { saved.name = template.name }
                onSave(saved)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                    Text("Save Procedure")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
    }

    // MARK: - Helpers

    private func iconForAction(_ action: RecordedAction.ActionType) -> String {
        switch action {
        case .click: return "cursorarrow.click"
        case .typeText: return "keyboard"
        case .keyPress: return "command"
        case .appSwitch: return "square.on.square"
        case .scroll: return "scroll"
        }
    }

    private func colorForAction(_ action: RecordedAction.ActionType) -> Color {
        switch action {
        case .click: return .blue
        case .typeText: return .green
        case .keyPress: return .orange
        case .appSwitch: return .purple
        case .scroll: return .gray
        }
    }

    private func describeAction(_ action: RecordedAction.ActionType) -> String {
        switch action {
        case .click(let x, let y, let button, let count):
            let clicks = count > 1 ? "\(count)x " : ""
            return "\(clicks)\(button) click at (\(Int(x)), \(Int(y)))"
        case .typeText(let text):
            let truncated = String(text.prefix(40))
            return "Type \"\(truncated)\(text.count > 40 ? "..." : "")\""
        case .keyPress(_, let keyName, let modifiers):
            return modifiers.isEmpty ? keyName : "\(modifiers.joined(separator: "+"))+\(keyName)"
        case .appSwitch(let toApp, _):
            return "Switch to \(toApp)"
        case .scroll(_, let deltaY, _, _):
            return "Scroll \(deltaY > 0 ? "up" : "down")"
        }
    }
}
