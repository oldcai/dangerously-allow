import Foundation

/// The Messages API wire format for asking a model to *label* a menu — the
/// request body and the response parse. Pure: no network here (that lives in
/// the executable's `NetworkAdjudicator`), so both directions are unit-tested
/// against recorded bytes.
///
/// The model labels every row and says whether the whole thing is a permission
/// prompt. It never chooses a row — the caller reconciles these labels with the
/// rule engine's and lets `AllowPolicy` pick, per `Adjudication`.
public enum AdjudicatorAPI {
    public static let toolName = "judge_prompt"

    public static let systemPrompt = """
    You classify a terminal menu shown by a coding agent (Claude Code, Gemini \
    CLI, Codex) or by macOS. You do NOT choose a row — you only label what each \
    row means, and say whether the menu is a permission/approval request at all.

    Label every row with one kind:
    - allowOnce   grants the action this one time. e.g. "Yes", "Allow once", "Proceed".
    - allowSession grants until the agent process exits. e.g. "Allow for this session".
    - allowAlways grants beyond this run — a persistent or broad grant. e.g. "Allow \
    for all future sessions", "Yes, and don't ask again", "bypass permissions", AND \
    any option that trusts a folder/directory ("Trust folder", "Yes, I trust this \
    folder") since that lets the directory's config run code in every future session.
    - deny        refuses. e.g. "No", "Deny", "No, suggest changes", "Cancel", "exit".
    - neutral     neither grants nor refuses. e.g. "Modify with external editor".

    When unsure whether a grant is session-scoped or broader, label it the BROADER \
    kind — a label that overstates persistence only costs an approval, while one that \
    understates it can leak a lasting grant. Set is_permission_prompt to false for an \
    ordinary numbered list, a theme picker, or a model picker. Call \(toolName) once.
    """

    static let toolSchema: JSONValue = .object([
        "name": .string(toolName),
        "description": .string("Label each row of a terminal menu and say whether it is a permission request."),
        "input_schema": .object([
            "type": .string("object"),
            "properties": .object([
                "is_permission_prompt": .object([
                    "type": .string("boolean"),
                    "description": .string("True only if this menu is a permission/approval request."),
                ]),
                "options": .object([
                    "type": .string("array"),
                    "description": .string("One entry per numbered row, labelling what it grants."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "number": .object(["type": .string("integer")]),
                            "kind": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("allowOnce"), .string("allowSession"),
                                    .string("allowAlways"), .string("deny"), .string("neutral"),
                                ]),
                            ]),
                        ]),
                        "required": .array([.string("number"), .string("kind")]),
                    ]),
                ]),
                "reason": .object([
                    "type": .string("string"),
                    "description": .string("One short sentence."),
                ]),
            ]),
            "required": .array([.string("is_permission_prompt"), .string("options"), .string("reason")]),
        ]),
    ])

    static func userMessage(context: [String], options: [MenuRow]) -> String {
        var s = "A coding agent or macOS is showing this menu. The rule-based "
        s += "classifier did not recognise it.\n\n--- SCREEN ---\n"
        s += context.joined(separator: "\n")
        s += "\n--- ROWS ---\n"
        for row in options { s += "\(row.number). \(row.label)\n" }
        s += "--- END ---\nLabel every row by its number."
        return s
    }

    public static func buildRequestBody(
        context: [String], options: [MenuRow], model: String, maxTokens: Int = 512
    ) -> JSONValue {
        .object([
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "system": .string(systemPrompt),
            "tool_choice": .object(["type": .string("tool"), "name": .string(toolName)]),
            "tools": .array([toolSchema]),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string(userMessage(context: context, options: options)),
                ]),
            ]),
        ])
    }

    public static func encodedRequest(
        context: [String], options: [MenuRow], model: String, maxTokens: Int = 512
    ) throws -> Data {
        try buildRequestBody(context: context, options: options, model: model, maxTokens: maxTokens).encoded()
    }

    private struct APIResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let input: JudgeInput?
        }
        struct JudgeInput: Decodable {
            let is_permission_prompt: Bool?
            let options: [Row]?
            let reason: String?
            struct Row: Decodable {
                let number: Int
                let kind: String
            }
        }
    }

    /// Extract the judgment, or nil if the reply carried no tool call. An
    /// unrecognised `kind` string maps to `.deny` — the most reluctant kind, so a
    /// garbled label can only withhold a grant, never invent one.
    public static func parse(responseData: Data) -> PromptJudgment? {
        guard let resp = try? JSONDecoder().decode(APIResponse.self, from: responseData),
              let input = resp.content.first(where: { $0.type == "tool_use" && $0.input != nil })?.input
        else { return nil }
        let options = (input.options ?? []).map {
            OptionJudgment(number: $0.number, kind: OptionKind(rawValue: $0.kind) ?? .deny)
        }
        return PromptJudgment(
            isPermissionPrompt: input.is_permission_prompt ?? false,
            options: options,
            reason: input.reason ?? ""
        )
    }
}
