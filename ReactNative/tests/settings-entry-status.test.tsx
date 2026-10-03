import type {PropsWithChildren} from 'react';
import {View} from 'react-native';
import {act, fireEvent, render, screen} from '@testing-library/react-native';
import type {AppSnapshot} from '../app/contract';
import type {AppStore} from '../app/store';
import {ReviewContext, type ReviewState} from '../review/ReviewContext';
import {SettingsScreen, AccountScreen} from '../review/SettingsScreens';
import {DeviceQAScreen, FeedbackSettingsScreen} from '../review/NativePageScreen';
import {initialSession} from '../review/session';

const mockNavigate = jest.fn();
const mockGoBack = jest.fn();
const mockNavigation = {navigate: mockNavigate, goBack: mockGoBack, setOptions: jest.fn()};
jest.mock('@react-navigation/native', () => ({useNavigation: () => mockNavigation, useIsFocused: () => true, usePreventRemove: jest.fn(), useScrollToTop: jest.fn()}));
jest.mock('react-native-safe-area-context', () => ({useSafeAreaInsets: () => ({top: 59, bottom: 34, left: 0, right: 0})}));
jest.mock('../specs/LavaDecorationNativeComponent', () => ({__esModule: true, default: require('react-native').View}));
jest.mock('../specs/LavaNativePageNativeComponent', () => ({__esModule: true, default: require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent', () => require('./native-choice-mock'));
jest.mock('../specs/LavaSliderNativeComponent', () => ({__esModule: true, default: require('react-native').View}));
jest.mock('../specs/NativeLavaReview', () => ({__esModule: true, default: {getGuardAccents: () => '{}', close: jest.fn()}}));

const base = {
  qaTools: true, plus: {enabled: false}, account: {signedIn: true},
  backup: {enablement: {state:'on',value:true,canEnable:false,canDisable:true,canBackUp:true,canRestore:true,canChangeAutomatic:true,canRetryDeletion:false},
    configured: true, automatic: true, busy: false, backingUp: false,
    summary: 'Last updated at 19:23, Sep 12, 2026', detail: '', needsAttention:false},
} as unknown as AppSnapshot;
function Provider({children, live = base, app}: PropsWithChildren<{live?: AppSnapshot; app?: AppStore}>) {
  return <ReviewContext.Provider value={{app, live, session: initialSession(), setSession: jest.fn()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
}
beforeEach(() => {mockNavigate.mockClear(); mockGoBack.mockClear();});

test('Settings keeps shared destination indicators and includes the native pages', () => {
  render(<Provider><SettingsScreen /></Provider>);
  const rows = screen.getAllByTestId(/^row\.[^.]+$/);
  expect(rows.length).toBeGreaterThanOrEqual(10);
  for (const row of rows) {
    const indicators = row.findAll((node: {type: unknown; props: {symbol?: string}}) => node.type === View && ['chevron.right','arrow.up.right'].includes(node.props.symbol??''));
    expect(indicators).toHaveLength(1);
    expect(indicators[0]!.props.accessible).toBe(false);
    expect(row.props.accessibilityRole).toBe('button');
  }
  expect(screen.getByTestId('row.Device QA')).toBeTruthy();
  expect(screen.getByTestId('row.Feedback')).toBeTruthy();
});

test('Settings Feedback opens its native sheet while Device QA preserves its settings authorization', async () => {
  const command = jest.fn(async () => null);
  render(<Provider app={{command} as unknown as AppStore}><SettingsScreen /></Provider>);
  fireEvent.press(screen.getByTestId('row.Feedback'));
  expect(command).toHaveBeenCalledWith({type:'native.flow',flow:'feedback'});
  expect(mockNavigate).not.toHaveBeenCalledWith('Feedback');
  await act(async () => fireEvent.press(screen.getByTestId('row.Device QA')));
  expect(command).toHaveBeenCalledWith({type: 'navigation.authorize', surface: 'appSettings'});
  expect(mockNavigate).toHaveBeenLastCalledWith('DeviceQA');
  expect(command.mock.calls).toHaveLength(2);
});

test.each([
  [FeedbackSettingsScreen, 'feedback-settings-page', 'feedback'],
  [DeviceQAScreen, 'device-qa-page', 'phoneQA'],
] as const)('native Settings page %s returns through its owning React stack', (Component, id, page) => {
  render(<Provider app={{command: jest.fn()} as unknown as AppStore}><Component /></Provider>);
  const nativePage = screen.getByTestId(id);
  expect(nativePage.props.page).toBe(page);
  fireEvent(nativePage, 'back');
  expect(mockGoBack).toHaveBeenCalledTimes(1);
});

test.each([
  ['on', true, true, 'Last updated at 19:23, Sep 12, 2026'],
  ['off', false, true, 'No backup'],
  ['unavailable', null, true, 'Backup status unavailable'],
  ['signed out', false, false, 'Ready after sign-in'],
] as const)('backup %s uses the current native enablement state', (_state, value, signedIn, expected) => {
  const enablement = {...base.backup.enablement!,state:value===null?'unavailable':value?'on':'off',value};
  const live = {...base, account:{...base.account,signedIn}, backup:{...base.backup,enablement,
    summary:value===true?expected:'Not uploaded yet',detail:expected}} as AppSnapshot;
  render(<Provider live={live}><AccountScreen /></Provider>);
  expect(screen.getAllByText(expected)).toHaveLength(1);
  if (value!==true) expect(screen.queryByText('Back up now')).toBeNull();
});

test('backup summary follows the latest native snapshot', () => {
  const {rerender} = render(<Provider><AccountScreen /></Provider>);
  expect(screen.getAllByText(base.backup.summary)).toHaveLength(1);
  rerender(<Provider live={{...base, backup: {...base.backup, summary: 'Updated just now'}}}><AccountScreen /></Provider>);
  expect(screen.queryByText(base.backup.summary)).toBeNull();
  expect(screen.getAllByText('Updated just now')).toHaveLength(1);
});
