import type {LavaChoiceProps} from './contracts';

export function LavaChoice<Value extends string>(_props: LavaChoiceProps<Value>): never {
  throw new Error('LavaChoice needs this platform’s native component mapping.');
}
