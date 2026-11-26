import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';

void main() {
  test('streamed parts keep the gateway event order', () {
    final item = NgAssistantItem('a');
    item.appendReasoning('first thought');
    item.appendText('answer one');
    item.addTool(NgTool(id: 't1', name: 'shell'));
    item.appendReasoning('second thought');
    item.appendText('answer two');

    expect(
      item.parts.map((p) => p.kind).toList(),
      [
        NgPartKind.reasoning,
        NgPartKind.text,
        NgPartKind.tool,
        NgPartKind.reasoning,
        NgPartKind.text,
      ],
    );
    expect(item.parts.where((p) => p.kind == NgPartKind.reasoning).length, 2);
  });

  test('stored history thoughts stay separate blocks', () {
    final item = NgAssistantItem('a');
    item.addReasoningBlock('A');
    item.addReasoningBlock('B');
    expect(
      item.parts
          .where((p) => p.kind == NgPartKind.reasoning)
          .map((p) => p.text)
          .toList(),
      ['A', 'B'],
    );
  });

  test('final answer replaces stream chunks without moving tools', () {
    final item = NgAssistantItem('a');
    item.appendText('partial');
    item.addTool(NgTool(id: 't', name: 'read_file'));
    item.replaceText('final');
    expect(
      item.parts.map((p) => p.kind).toList(),
      [NgPartKind.tool, NgPartKind.text],
    );
    expect(item.text, 'final');
  });
}
