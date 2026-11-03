import argparse
import os
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


def configure(volume):
    background = volume / '.background/background.png'
    with DSStore.open(str(volume / '.DS_Store'), 'w+') as store:
        store['.']['vSrn'] = ('long', 1)
        store['.']['vstl'] = ('type', b'icnv')
        store['.']['bwsp'] = {
            'WindowBounds': '{{140, 120}, {760, 480}}',
            'ShowToolbar': False,
            'ShowStatusBar': False,
            'ShowTabView': False,
            'ShowPathbar': False,
            'ShowSidebar': False,
            'SidebarWidth': 0,
            'ContainerShowSidebar': False,
        }
        store['.']['icvp'] = {
            'viewOptionsVersion': 1,
            'backgroundType': 2,
            'backgroundImageAlias': Alias.for_file(str(background)).to_bytes(),
            'iconSize': 112.0,
            'textSize': 14.0,
            'arrangeBy': 'none',
            'labelOnBottom': True,
            'showItemInfo': False,
            'showIconPreview': True,
            'gridOffsetX': 0.0,
            'gridOffsetY': 0.0,
            'gridSpacing': 100.0,
            'scrollPositionX': 0.0,
            'scrollPositionY': 0.0,
        }
        store['Slip.app']['Iloc'] = (190, 240)
        store['Applications']['Iloc'] = (570, 240)


def verify(volume):
    if not (volume / 'Slip.app/Contents/MacOS/Slip').is_file():
        raise ValueError('The disk image is missing the native executable')
    if not (volume / '.background/background.png').is_file():
        raise ValueError('The disk image is missing its background')
    if not (volume / 'Applications').is_symlink() or os.readlink(volume / 'Applications') != '/Applications':
        raise ValueError('The disk image is missing its Applications shortcut')
    with DSStore.open(str(volume / '.DS_Store'), 'r') as store:
        if store['.']['vstl'] != (b'type', b'icnv'):
            raise ValueError('The disk image must open in icon view')
        options = store['.']['icvp']
        if options['backgroundType'] != 2 or not options['backgroundImageAlias']:
            raise ValueError('The disk image has no Finder background reference')
        alias = Alias.from_bytes(options['backgroundImageAlias'])
        if alias.target.filename != 'background.png':
            raise ValueError('The disk image background reference is invalid')
        if store['Slip.app']['Iloc'] != (190, 240) or store['Applications']['Iloc'] != (570, 240):
            raise ValueError('The drag-to-Applications layout was not saved')
    print('Verified installer contents, background reference and icon positions')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('volume', type=Path)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if not args.verify:
        configure(args.volume)
    verify(args.volume)
