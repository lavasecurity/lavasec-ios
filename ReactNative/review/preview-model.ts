// Deliberately separate from native snapshots/commands. These reserved example
// domains and filter names are display fixtures, never production configuration.
export const previewDomains = ['ads.example.com', 'tracker.example.net', 'metrics.example.org'] as const;
export type PreviewDraft = {blocked: string[]; allowed: string[]};
export const initialPreviewDraft = (): PreviewDraft => ({blocked: [], allowed: []});

export function previewDiff(baseline: PreviewDraft, draft: PreviewDraft) {
  return {
    blockedAdded: draft.blocked.filter(domain => !baseline.blocked.includes(domain)),
    blockedRemoved: baseline.blocked.filter(domain => !draft.blocked.includes(domain)),
    allowedAdded: draft.allowed.filter(domain => !baseline.allowed.includes(domain)),
    allowedRemoved: baseline.allowed.filter(domain => !draft.allowed.includes(domain)),
  };
}

export function addPreviewDomain(draft: PreviewDraft, input: string, normalize: (input: string) => string | null, decision: 'blocked' | 'allowed' = 'blocked'): PreviewDraft {
  const domain = normalize(input);
  if (!domain) throw new Error('Enter a valid domain, such as ads.example.com.');
  if (draft[decision].includes(domain)) return draft;
  return {...draft, [decision]: [...draft[decision], domain]};
}
