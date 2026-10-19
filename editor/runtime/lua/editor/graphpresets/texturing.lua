-- Reads the heights of the map and paints texture layers by rules: cliffs, beach and snow. Layers 2, 3 and 4.
Graph = {
    ['name'] = 'Texture the existing terrain (no height change)',
    ['nextId'] = 8,
    ['nodes'] = {
        { ['id'] = 1, ['params'] = {}, ['type'] = 'terrain', ['x'] = 0, ['y'] = 0 },
        { ['id'] = 2, ['params'] = { ['preset'] = 'beach' }, ['type'] = 'mask_preset', ['x'] = 224, ['y'] = 0 },
        {
            ['id'] = 3,
            ['params'] = { ['preset'] = 'cliffs' },
            ['type'] = 'mask_preset',
            ['x'] = 224,
            ['y'] = 152,
        },
        {
            ['id'] = 4,
            ['params'] = { ['preset'] = 'snow' },
            ['type'] = 'mask_preset',
            ['x'] = 224,
            ['y'] = 304,
        },
        { ['id'] = 5, ['params'] = { ['layer'] = 2 }, ['type'] = 'out_layer', ['x'] = 448, ['y'] = 0 },
        { ['id'] = 6, ['params'] = { ['layer'] = 3 }, ['type'] = 'out_layer', ['x'] = 448, ['y'] = 152 },
        { ['id'] = 7, ['params'] = { ['layer'] = 4 }, ['type'] = 'out_layer', ['x'] = 448, ['y'] = 304 },
    },
    ['seed'] = 1,
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
            1,
            'out',
            3,
            'a',
        },
        {
            1,
            'out',
            4,
            'a',
        },
        {
            2,
            'out',
            5,
            'a',
        },
        {
            3,
            'out',
            6,
            'a',
        },
        {
            4,
            'out',
            7,
            'a',
        },
    },
}
