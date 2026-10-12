import {Dimensions} from 'react-native';

// RN's stock Jest window is 750 logical points. Ordinary component fixtures
// represent a phone; tablet and windowing cases set their geometry explicitly.
Dimensions.set({window:{width:390,height:844,scale:3,fontScale:1},screen:{width:390,height:844,scale:3,fontScale:1}});
