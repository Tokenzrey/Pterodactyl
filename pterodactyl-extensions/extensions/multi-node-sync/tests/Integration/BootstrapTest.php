<?php

declare(strict_types=1);

use MultiNodeSync\Tests\ExtensionTestCase;

uses(ExtensionTestCase::class);

it('boots the multi-node-sync extension', function (): void {
    expect(true)->toBeTrue();
});
