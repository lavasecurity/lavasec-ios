import {LavaChoice} from '../../choice';
import type {LavaPurposeChoiceProps} from '../contracts';

export type {LavaPurposeChoiceProps} from '../contracts';
/** Same platform renderer and options; each facade names its caller's purpose. */
export function LavaSingleChoice<Value extends string>(props:LavaPurposeChoiceProps<Value>) {
  return <LavaChoice {...props} presentation="segments"/>;
}
export function LavaOptionStepper<Value extends string>(props:LavaPurposeChoiceProps<Value>) {
  return <LavaChoice {...props} presentation="stepper"/>;
}
export function LavaPageIndicator<Value extends string>(props:LavaPurposeChoiceProps<Value>) {
  return <LavaChoice {...props} presentation="pages"/>;
}
