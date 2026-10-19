-- Hills mirrored across both axes, exact copies: a fair, symmetric map by construction. Change the mode to rotate for a two-player map.
Graph = {
    ['name'] = 'Symmetric hills (four-fold mirror)',
    ['nextId'] = 7,
    ['nodes'] = {
        {
            ['id'] = 1,
            ['params'] = { ['octaves'] = 5, ['scale'] = 110 },
            ['type'] = 'simplex',
            ['x'] = 0,
            ['y'] = 0,
        },
        { ['id'] = 2, ['params'] = { ['hi'] = 54, ['lo'] = 30 }, ['type'] = 'range', ['x'] = 224, ['y'] = 0 },
        { ['id'] = 3, ['params'] = { ['mode'] = 'xz' }, ['type'] = 'mirror', ['x'] = 448, ['y'] = 0 },
        {
            ['id'] = 4,
            ['params'] = { ['iterations'] = 25, ['talus'] = 0.5 },
            ['type'] = 'thermal',
            ['x'] = 672,
            ['y'] = 0,
        },
        { ['id'] = 5, ['params'] = {}, ['type'] = 'out_height', ['x'] = 896, ['y'] = 0 },
        {
            ['id'] = 6,
            ['params'] = { ['preset'] = 'blocked' },
            ['type'] = 'mask_preset',
            ['x'] = 896,
            ['y'] = 152,
        },
    },
    ['seed'] = 8,
    ['version'] = 1,
    ['view'] = { ['x'] = 20, ['y'] = 20, ['zoom'] = 0.8 },
    ['wires'] = {
        {
            1,
            'out',
            2,
            'a',
        },
        {
            2,
            'out',
            3,
            'a',
        },
        {
            3,
            'out',
            4,
            'a',
        },
        {
            4,
            'out',
            5,
            'a',
        },
        {
            4,
            'out',
            6,
            'a',
        },
    },
}
