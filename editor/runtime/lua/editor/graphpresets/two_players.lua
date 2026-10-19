-- Hills with a base pad, turned by 180 degrees so both bases and all terrain are exact copies, then the slope limited to what units can cross. For a real map set the pad node to markers mode (pads under the start positions and resource markers).
Graph = {
    ['name'] = 'Two player map (symmetric, flat bases, pathable)',
    ['nextId'] = 8,
    ['nodes'] = {
        {
            ['id'] = 1,
            ['params'] = { ['octaves'] = 5, ['scale'] = 110 },
            ['type'] = 'simplex',
            ['x'] = 0,
            ['y'] = 0,
        },
        { ['id'] = 2, ['params'] = { ['hi'] = 60, ['lo'] = 30 }, ['type'] = 'range', ['x'] = 224, ['y'] = 0 },
        {
            ['id'] = 3,
            ['params'] = { ['half'] = 10, ['skirt'] = 16, ['source'] = 'one', ['x'] = 0.2, ['z'] = 0.2 },
            ['type'] = 'pad_flatten',
            ['x'] = 448,
            ['y'] = 0,
        },
        { ['id'] = 4, ['params'] = { ['mode'] = 'rot2' }, ['type'] = 'symmetrize', ['x'] = 672, ['y'] = 0 },
        {
            ['id'] = 5,
            ['params'] = { ['limit'] = 0.7, ['mode'] = 'both' },
            ['type'] = 'slope_limit',
            ['x'] = 896,
            ['y'] = 0,
        },
        { ['id'] = 6, ['params'] = {}, ['type'] = 'out_height', ['x'] = 1120, ['y'] = 0 },
        {
            ['id'] = 7,
            ['params'] = { ['which'] = 'blocked' },
            ['type'] = 'unit_slope',
            ['x'] = 1120,
            ['y'] = 152,
        },
    },
    ['seed'] = 14,
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
            5,
            'out',
            6,
            'a',
        },
        {
            5,
            'out',
            7,
            'a',
        },
    },
}
