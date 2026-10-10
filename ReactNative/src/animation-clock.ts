/** Durations use a monotonic clock so a wall-clock adjustment cannot complete
 * a handoff early, reverse an expression or strand its native completion gate. */
declare const performance:{now():number};
export const animationNow=()=>performance.now()/1000;
