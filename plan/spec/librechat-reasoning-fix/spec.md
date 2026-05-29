# Fix: Preserve reasoning_content in assistant messages with tool calls

## Metadata

- **Status**: Ready for implementation
- **Upstream**: https://github.com/danny-avila/agents (separate repo from LibreChat)
- **LibreChat integration**: https://github.com/danny-avila/LibreChat
- **Related issues**:
  - https://github.com/danny-avila/LibreChat/issues/11563 (Kimi-2.5 Interleaved Reasoning)
  - https://github.com/danny-avila/LibreChat/issues/10744 (DeepSeek-V3.2 Thinking-Mode)
- **Models affected**: Moonshot Kimi K2.6, DeepSeek V3.2 / deepseek-chat
- **Package**: `@librechat/agents` v3.1.68+
- **Workspace**: 
  - Main: `/Users/jose/Code/infra/homelab/builder/repos/librechat` (reference)
  - Fix worktree: `/Users/jose/Code/infra/homelab/builder/repos/librechat-fix-reasoning`
  - Agents repo: `/Users/jose/Code/infra/homelab/builder/repos/librechat-agents`

## Summary

LibreChat drops `reasoning_content` from assistant messages when tool calls are present. Both Moonshot Kimi K2.6 and DeepSeek models enable thinking mode by default. When the model generates reasoning followed by tool calls, the agent system reconstructs the message history for the next API call but strips the `reasoning_content` field. The API then rejects the request.

**The bug is in the `@librechat/agents` npm package** (separate repo from LibreChat), specifically in the `formatAssistantMessage` function. This function processes assistant message content parts and reconstructs LangChain `AIMessage` objects. When it encounters `ContentTypes.THINK` parts, it sets a `hasReasoning` flag but **discards the actual reasoning content** instead of attaching it to the output message.

## Root cause analysis

### Bug location

**File**: `src/messages/format.ts` in `@librechat/agents` package  
**Function**: `formatAssistantMessage` (lines 284-420 in v3.1.68)  
**Repo**: https://github.com/danny-avila/agents

### Why reasoning is lost

```typescript
// Current buggy code (lines 376-383):
} else if (
  part.type === ContentTypes.THINK ||
  part.type === ContentTypes.THINKING ||
  part.type === ContentTypes.REASONING_CONTENT ||
  part.type === 'redacted_thinking'
) {
  hasReasoning = true;
  continue;  // ← BUG: reasoning content is discarded here
}
```

When processing assistant messages:
1. THINK parts are encountered and skipped with `continue`
2. The reasoning text (`part.think`, `part.reasoning`, etc.) is never captured
3. AIMessage objects are created with only `content` and `tool_calls` (lines 313, 319-321, 346)
4. No `additional_kwargs.reasoning_content` is set
5. On the next API call, LangChain serializes the message without reasoning_content
6. The API rejects the request because thinking is enabled but reasoning_content is missing

### Why it only affects tool calls

Without tool calls, the assistant message is a single turn. The reasoning content is streamed to the UI and the conversation ends. With tool calls, the agent must:
1. Send the assistant message (with reasoning + tool_calls) to the API
2. Execute tools
3. Reconstruct the message history INCLUDING the reasoning
4. Send the reconstructed history back to the API

Steps 3-4 are where reasoning_content is lost.

## PR Strategy

### Primary: Submit PR upstream to `danny-avila/agents`

This is the proper fix. The `@librechat/agents` package is a separate open-source repo:
- **Repository**: https://github.com/danny-avila/agents
- **License**: MIT
- **Package**: published to npm as `@librechat/agents`

**Why this is the best approach**:
- Fixes the bug at the source
- Benefits all LibreChat users
- Cleanest implementation
- Can be merged and published to npm

### Secondary: Patch our NixOS deployment immediately

While waiting for upstream merge:
1. Use `patch-package` to patch `@librechat/agents` in our LibreChat build
2. Or use a Nix overlay to apply a patch during the build
3. Remove the `thinking: disabled` workaround from our config

**We will do both**: Submit the PR upstream AND patch our deployment.

## Implementation plan

### Phase 1: Write failing tests (red)

**Target**: `src/messages/formatAgentMessages.test.ts` in `@librechat/agents`

Add tests that verify reasoning_content is preserved:

1. **Test: reasoning + tool_calls**:
   ```typescript
   it('preserves reasoning_content when assistant message has tool calls', () => {
     const payload: TPayload = [{
       role: 'assistant',
       content: [
         { type: ContentTypes.THINK, think: 'I need to search...' },
         { type: ContentTypes.TEXT, text: 'Let me search.', tool_call_ids: ['call_1'] },
         { type: ContentTypes.TOOL_CALL, tool_call: { id: 'call_1', name: 'search', args: '{}', output: 'result' } }
       ]
     }];
     const { messages } = formatAgentMessages(payload);
     const assistantMsg = messages.find(m => m instanceof AIMessage && m.tool_calls?.length > 0);
     expect(assistantMsg?.additional_kwargs?.reasoning_content).toBe('I need to search...');
   });
   ```

2. **Test: reasoning without tool_calls**:
   - Verifies reasoning is preserved in plain assistant messages too

3. **Test: multiple reasoning parts**:
   - Verifies multiple THINK parts are concatenated or the last one is used

4. **Test: field name variants**:
   - Test THINK (`.think`), THINKING (`.thinking`), REASONING_CONTENT (`.reasoningText.text`)

5. **Test: no regression for non-reasoning messages**:
   - Ensure existing behavior is unchanged

**Verification**:
```bash
cd repos/librechat-agents
npm test -- src/messages/formatAgentMessages.test.ts
# All new tests MUST FAIL (red state)
```

**Commit**:
```bash
git add src/messages/formatAgentMessages.test.ts
git commit -m "Add failing tests for reasoning_content preservation with tool calls"
```

### Phase 2: Fix formatAssistantMessage

**Target**: `src/messages/format.ts` in `@librechat/agents`  
**Function**: `formatAssistantMessage` (lines 284-420)

**Changes**:
1. Capture reasoning content when encountering THINK/THINKING/REASONING_CONTENT parts
2. Attach `additional_kwargs.reasoning_content` to AIMessage when reasoning exists
3. Handle field name variants (`.think`, `.thinking`, `.reasoningText.text`)

**Implementation sketch**:
```typescript
function formatAssistantMessage(message: Partial<TMessage>): Array<AIMessage | ToolMessage> {
  const formattedMessages: Array<AIMessage | ToolMessage> = [];
  let currentContent: MessageContentComplex[] = [];
  let lastAIMessage: AIMessage | null = null;
  let reasoningContent: string | null = null;  // NEW: accumulate reasoning

  if (Array.isArray(message.content)) {
    for (const part of message.content) {
      if (part == null) continue;

      // NEW: Capture reasoning content instead of just setting a flag
      if (part.type === ContentTypes.THINK) {
        reasoningContent = (part as ReasoningContentText).think || '';
        continue;
      } else if (part.type === ContentTypes.THINKING) {
        reasoningContent = (part as ThinkingContentText).thinking || '';
        continue;
      } else if (part.type === ContentTypes.REASONING_CONTENT) {
        reasoningContent = (part as BedrockReasoningContentText).reasoningText?.text || '';
        continue;
      } else if (part.type === 'redacted_thinking') {
        continue;
      }

      if (part.type === ContentTypes.TEXT && part.tool_call_ids) {
        // ... existing logic ...
        lastAIMessage = new AIMessage({
          content: part.text != null ? part.text : '',
          additional_kwargs: reasoningContent ? { reasoning_content: reasoningContent } : undefined,
        });
        formattedMessages.push(lastAIMessage);
        reasoningContent = null;  // Reset for next segment
      } else if (part.type === ContentTypes.TOOL_CALL) {
        // ... existing logic ...
        if (!lastAIMessage) {
          lastAIMessage = new AIMessage({
            content: '',
            additional_kwargs: reasoningContent ? { reasoning_content: reasoningContent } : undefined,
          });
          formattedMessages.push(lastAIMessage);
        }
        // ... rest of tool call handling ...
      }
      // ... rest of existing logic ...
    }
  }

  // ... existing final content handling with reasoningContent ...
}
```

**Verification**:
```bash
cd repos/librechat-agents
npm test -- src/messages/formatAgentMessages.test.ts
# All tests MUST PASS (green state)
```

**Commit**:
```bash
git add src/messages/format.ts
git commit -m "Preserve reasoning_content in assistant messages with tool calls"
```

### Phase 3: Verify in LibreChat context

1. **Build the agents package**:
   ```bash
   cd repos/librechat-agents
   npm run build
   ```

2. **Copy built package to LibreChat**:
   ```bash
   cd repos/librechat-fix-reasoning
   cp -r ../librechat-agents/dist node_modules/@librechat/agents/dist
   ```

3. **Run LibreChat tests**:
   ```bash
   cd repos/librechat-fix-reasoning
   npm test -- api/server/controllers/agents/
   ```

4. **Build LibreChat**:
   ```bash
   cd repos/librechat-fix-reasoning
   npm run build
   ```

### Phase 4: Submit PR upstream

1. **Push to fork**:
   ```bash
   cd repos/librechat-agents
   git remote add fork https://github.com/YOUR_USERNAME/agents.git
   git push fork fix/reasoning-tool-calls
   ```

2. **Create PR** on https://github.com/danny-avila/agents
   - Title: `fix: Preserve reasoning_content in assistant messages with tool calls`
   - Reference: LibreChat issues #11563 and #10744
   - Include test cases and explanation

### Phase 5: Patch NixOS deployment

While waiting for upstream merge:

1. **Create a patch file** from the agents fix:
   ```bash
   cd repos/librechat-agents
   git diff main > ../reasoning-content-fix.patch
   ```

2. **Update NixOS configuration**:
   - Add the patch to the LibreChat derivation in nixpkgs
   - Or use `patch-package` in the build
   - Remove `thinking: disabled` workaround from `machines/house/src/service/librechat.nix`

3. **Deploy and verify**:
   ```bash
   just deploy-remote house
   ```
   - Test Moonshot Kimi K2.6 with web search
   - Test DeepSeek with web search
   - Verify reasoning content is displayed in UI

## Feedback mechanism

**Strategy: red test**

Tests are written first and must fail before implementation begins.

### Level 1 verification commands

```bash
# In @librechat/agents repo
cd repos/librechat-agents
npm test -- src/messages/formatAgentMessages.test.ts

# Run all message format tests
npm test -- src/messages/

# Build check
npm run build
```

### Level 2 verification (LibreChat integration)

```bash
# In LibreChat repo with patched agents
cd repos/librechat-fix-reasoning
npm test -- api/server/controllers/agents/
npm run build
```

### Red test criteria

Before implementation:
- [ ] Tests for reasoning + tool_calls FAIL
- [ ] Tests for reasoning without tool_calls FAIL
- [ ] Tests for multiple reasoning parts FAIL

After implementation:
- [ ] All reasoning tests PASS
- [ ] Existing tests still PASS (no regressions)
- [ ] Build succeeds

## Remaining work

- [ ] Write failing tests in `librechat-agents/src/messages/formatAgentMessages.test.ts`
- [ ] Commit red tests
- [ ] Implement fix in `librechat-agents/src/messages/format.ts`
- [ ] Verify tests pass
- [ ] Commit implementation
- [ ] Build agents package
- [ ] Test in LibreChat context
- [ ] Submit PR to `danny-avila/agents`
- [ ] Create NixOS patch for immediate deployment
- [ ] Remove `thinking: disabled` workaround from NixOS config
- [ ] Deploy and verify on house
- [ ] Ship changes (commit + push infrastructure repo)

## Commit strategy

1. **In `librechat-agents` repo**:
   - `Add failing tests for reasoning_content preservation with tool calls`
   - `Preserve reasoning_content in assistant messages with tool calls`

2. **In infrastructure repo** (`vpc-hoster`):
   - `Add patch for LibreChat reasoning_content fix`
   - `Remove thinking disabled workaround for LibreChat`

## Workspace setup

```
/repos/
├── librechat/                  # Main LibreChat branch (reference)
├── librechat-fix-reasoning/    # Worktree for testing fix
└── librechat-agents/           # @librechat/agents repo (where fix is implemented)
```

All directories are gitignored in the infrastructure repo.

## Code examples (illustrative)

**Note**: Code examples are illustrative. Verify against actual codebase conventions and adjust as needed.

### Test example

```typescript
it('preserves reasoning_content when assistant has tool calls', () => {
  const payload: TPayload = [{
    role: 'assistant',
    content: [
      { type: ContentTypes.THINK, think: 'I need to search for this' },
      { type: ContentTypes.TEXT, text: 'Let me search.', tool_call_ids: ['call_1'] },
      { type: ContentTypes.TOOL_CALL, tool_call: {
        id: 'call_1', name: 'search', args: '{}', output: 'results'
      }}
    ]
  }];

  const { messages } = formatAgentMessages(payload);
  const assistantMsg = messages.find(
    m => m instanceof AIMessage && m.tool_calls && m.tool_calls.length > 0
  );

  expect(assistantMsg).toBeDefined();
  expect(assistantMsg!.additional_kwargs).toHaveProperty('reasoning_content');
  expect(assistantMsg!.additional_kwargs!.reasoning_content).toBe('I need to search for this');
});
```

### Fix example

```typescript
// In formatAssistantMessage, replace the hasReasoning flag approach:

// OLD:
let hasReasoning = false;
// ...
} else if (part.type === ContentTypes.THINK) {
  hasReasoning = true;
  continue;
}

// NEW:
let reasoningContent: string | null = null;
// ...
} else if (part.type === ContentTypes.THINK) {
  reasoningContent = (part as ReasoningContentText).think || '';
  continue;
}

// When creating AIMessage with tool_calls:
lastAIMessage = new AIMessage({
  content: part.text != null ? part.text : '',
  additional_kwargs: reasoningContent ? { reasoning_content: reasoningContent } : undefined,
});
```

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Upstream PR takes long to merge | We patch our NixOS deployment immediately |
| Different providers use different field names | Handle all variants: `.think`, `.thinking`, `.reasoningText.text` |
| LangChain doesn't serialize additional_kwargs correctly | Test with actual API calls in LibreChat integration |
| Breaking existing behavior | Comprehensive regression tests for non-reasoning paths |
| NixOS packaging complexity | Use `patch-package` or overlay approach; test build locally |

## Prior art

- https://github.com/danny-avila/LibreChat/issues/11563 — Kimi-2.5 Interleaved Reasoning
- https://github.com/danny-avila/LibreChat/issues/10744 — DeepSeek-V3.2 Thinking-Mode
- https://github.com/danny-avila/LibreChat/pull/11805 — Bedrock reasoning chain handling (different package, similar concept)

## Notes

- The `@librechat/agents` package is a **separate repo** from LibreChat. The fix must be submitted to `danny-avila/agents`, not `danny-avila/LibreChat`.
- The package source is included in `node_modules/@librechat/agents/src/` which made investigation possible.
- The fix is localized to a single function (`formatAssistantMessage`) and should be a clean, reviewable PR.
