import {render, screen} from '@testing-library/react-native';
import {StyleSheet, View} from 'react-native';
import {LavaCard, LavaText} from '../src';
import {colors} from '../src/colors.ios';

jest.mock('../src/generated/tokens', () => {
  const {lavaTokens} = jest.requireActual('../src/generated/tokens');
  return {lavaTokens: {...lavaTokens, surface: {...lavaTokens.surface,
    cardBackground: 'cream', panelBackground: 'softGreen', panelStroke: 'ink',
  }}};
});

it('renders remapped Swift surfaces instead of identically named palette colors', () => {
  render(<>
    <LavaCard testID="card"><LavaText>Card</LavaText></LavaCard>
    <LavaCard testID="panel" role="panel"><LavaText>Panel</LavaText></LavaCard>
  </>);
  expect(screen.getByTestId('card.content')).toHaveStyle({backgroundColor: colors.cream});
  expect(screen.getByTestId('panel.content')).toHaveStyle({
    backgroundColor: colors.softGreen,
  });
  const outline=screen.UNSAFE_getAllByType(View).find(node=>node.props.testID==='panel.surface');
  expect(StyleSheet.flatten(outline?.props.style)).toEqual(expect.objectContaining({
    borderColor: colors.ink, borderWidth: 1,
  }));
});
