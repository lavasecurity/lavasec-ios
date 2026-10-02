// The native adapter consumes the same Swift-owned metrics as the RN foundation.
// Resolve at preparation time so its Objective-C has no runtime bridge dependency.
export function renderToolbarAdapter(source, metrics) {
  const values = {
    __LAVA_MODE_GLYPH__: metrics.checkmarkIconPointSize,
    __LAVA_MODE_CANVAS__: metrics.iconFrameSize,
    __LAVA_MODE_TARGET__: metrics.buttonSize,
  };
  for (const [key, value] of Object.entries(values)) {
    if (!Number.isFinite(value) || value <= 0) throw new Error(`Invalid toolbar metric: ${key}`);
    if (!source.includes(key)) throw new Error(`Missing toolbar metric slot: ${key}`);
    source = source.replaceAll(key, String(value));
  }
  if (/__LAVA_MODE_\w+__/.test(source)) throw new Error('Unknown toolbar metric slot');
  return source;
}
