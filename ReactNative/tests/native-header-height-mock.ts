import {createContext,useContext} from 'react';

// Unit screens omit the native navigator; geometry tests can supply its real
// measured header height through the same context the app consumes.
export const HeaderHeightContext=createContext<number|undefined>(undefined);
export const useHeaderHeight=()=>useContext(HeaderHeightContext)??44;
