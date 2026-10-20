<?php

declare(strict_types=1);

use OauthLogin\Support\Profile;
use OauthLogin\Support\ProfileParser;

// FR-O7: only provider-verified emails are accepted. Fixtures follow the shape of the official docs
// (Discord "Get Current User", GitHub "Get the authenticated user" + "List email addresses",
// Google OpenID Connect userinfo).

function discordMe(array $override = []): array
{
    return $override + [
        'id' => '80351110224678912',
        'username' => 'nelly',
        'discriminator' => '0',
        'global_name' => 'Nelly',
        'avatar' => '8342729096ea3675442027381ff50dfe',
        'verified' => true,
        'email' => 'nelly@discord.com',
        'flags' => 64,
    ];
}

function githubUser(array $override = []): array
{
    return $override + ['login' => 'octocat', 'id' => 1, 'name' => 'monalisa octocat', 'email' => 'public@example.com'];
}

function githubEmails(array $entries = []): array
{
    return $entries ?: [
        ['email' => 'octocat@github.com', 'verified' => true, 'primary' => true, 'visibility' => 'public'],
        ['email' => 'second@example.com', 'verified' => true, 'primary' => false, 'visibility' => null],
    ];
}

function googleInfo(array $override = []): array
{
    return $override + [
        'sub' => '110248495921238986420',
        'name' => 'Ada Lovelace',
        'given_name' => 'Ada',
        'picture' => 'https://lh3.googleusercontent.com/a/x',
        'email' => 'ada@example.com',
        'email_verified' => true,
    ];
}

describe('discord', function (): void {
    test('verified email gives a profile', function (): void {
        expect(ProfileParser::discord(discordMe()))->toEqual(new Profile('80351110224678912', 'nelly@discord.com', 'nelly', 'Nelly'));
    });

    test('display name falls back to the username', function (): void {
        expect(ProfileParser::discord(discordMe(['global_name' => null]))?->displayName)->toBe('nelly');
    });

    test('AC-O10 unverified, missing or non-boolean verified flag gives null', function (mixed $verified): void {
        expect(ProfileParser::discord(discordMe(['verified' => $verified])))->toBeNull();
    })->with([false, null, 'true', 1, 0, '']);

    test('AC-O10 missing verified key gives null', function (): void {
        $me = discordMe();
        unset($me['verified']);
        expect(ProfileParser::discord($me))->toBeNull();
    });

    test('AC-O10 missing or null email gives null', function (): void {
        expect(ProfileParser::discord(discordMe(['email' => null])))->toBeNull();
        $me = discordMe();
        unset($me['email']);
        expect(ProfileParser::discord($me))->toBeNull();
    });

    test('EC-O1 email is lower-cased', function (): void {
        expect(ProfileParser::discord(discordMe(['email' => 'Nelly@Discord.COM']))?->email)->toBe('nelly@discord.com');
    });

    test('missing, empty or non-scalar id gives null', function (mixed $id): void {
        expect(ProfileParser::discord(discordMe(['id' => $id])))->toBeNull();
    })->with([null, '', [[]], [['1']], true, 1.5]); // arrays are wrapped: Pest spreads a dataset array into arguments

    test('EC-O1 numeric id is turned into a string', function (): void {
        expect(ProfileParser::discord(discordMe(['id' => 42]))?->providerUserId)->toBe('42');
    });
});

describe('github', function (): void {
    test('the primary verified entry is used, not the public profile email', function (): void {
        expect(ProfileParser::github(githubUser(), githubEmails()))
            ->toEqual(new Profile('1', 'octocat@github.com', 'octocat', 'monalisa octocat'));
    });

    test('EC-O6 no primary entry gives null even when another entry is verified', function (): void {
        $emails = [['email' => 'a@example.com', 'verified' => true, 'primary' => false]];
        expect(ProfileParser::github(githubUser(), $emails))->toBeNull();
    });

    test('AC-O10 primary but unverified gives null', function (): void {
        $emails = [['email' => 'a@example.com', 'verified' => false, 'primary' => true]];
        expect(ProfileParser::github(githubUser(), $emails))->toBeNull();
    });

    test('flags must be real booleans', function (): void {
        $emails = [['email' => 'a@example.com', 'verified' => 'true', 'primary' => 1]];
        expect(ProfileParser::github(githubUser(), $emails))->toBeNull();
    });

    test('an empty email list gives null', function (): void {
        expect(ProfileParser::github(githubUser(), []))->toBeNull();
    });

    test('malformed entries are skipped, a good one after them still counts', function (): void {
        $emails = ['junk', null, 5, ['verified' => true, 'primary' => true], ['email' => ['x'], 'verified' => true, 'primary' => true],
            ['email' => 'Good@Example.com', 'verified' => true, 'primary' => true]];
        expect(ProfileParser::github(githubUser(), $emails)?->email)->toBe('good@example.com');
    });

    test('name falls back to the login', function (): void {
        expect(ProfileParser::github(githubUser(['name' => null]), githubEmails())?->displayName)->toBe('octocat');
    });

    test('EC-O1 integer id becomes a string', function (): void {
        expect(ProfileParser::github(githubUser(['id' => 583231]), githubEmails())?->providerUserId)->toBe('583231');
    });

    test('missing id or login gives null', function (): void {
        $noId = githubUser();
        unset($noId['id']);
        $noLogin = githubUser();
        unset($noLogin['login']);
        expect(ProfileParser::github($noId, githubEmails()))->toBeNull()
            ->and(ProfileParser::github($noLogin, githubEmails()))->toBeNull();
    });
});

describe('google', function (): void {
    test('verified email gives a profile whose hint is the local part', function (): void {
        expect(ProfileParser::google(googleInfo()))->toEqual(new Profile('110248495921238986420', 'ada@example.com', 'ada', 'Ada Lovelace'));
    });

    test('the long numeric sub stays a string', function (): void {
        expect(ProfileParser::google(googleInfo())?->providerUserId)->toBe('110248495921238986420');
    });

    test('email_verified may be the string "true" but nothing else truthy', function (): void {
        expect(ProfileParser::google(googleInfo(['email_verified' => 'true'])))->not->toBeNull();
        foreach ([false, 'false', null, 1, 'yes', ''] as $value) {
            expect(ProfileParser::google(googleInfo(['email_verified' => $value])))->toBeNull();
        }
    });

    test('AC-O10 missing email or email_verified gives null', function (): void {
        $noEmail = googleInfo();
        unset($noEmail['email']);
        $noFlag = googleInfo();
        unset($noFlag['email_verified']);
        expect(ProfileParser::google($noEmail))->toBeNull()
            ->and(ProfileParser::google($noFlag))->toBeNull();
    });

    test('EC-O1 email is lower-cased', function (): void {
        expect(ProfileParser::google(googleInfo(['email' => 'Ada@Example.COM']))?->email)->toBe('ada@example.com');
    });

    test('a missing name gives an empty display name', function (): void {
        $info = googleInfo();
        unset($info['name']);
        expect(ProfileParser::google($info)?->displayName)->toBe('');
    });

    test('missing or empty sub gives null', function (): void {
        expect(ProfileParser::google(googleInfo(['sub' => ''])))->toBeNull()
            ->and(ProfileParser::google(googleInfo(['sub' => null])))->toBeNull();
    });
});

describe('email shape (shared by all providers)', function (): void {
    test('hostile or malformed addresses are rejected before they can reach mail or the database', function (string $email): void {
        expect(ProfileParser::google(googleInfo(['email' => $email])))->toBeNull();
    })->with([
        'no at sign' => ['ada.example.com'],
        'two at signs' => ['a@b@example.com'],
        'empty local part' => ['@example.com'],
        'empty domain' => ['ada@'],
        'space inside' => ['a da@example.com'],
        'header injection' => ["ada@example.com\r\nBcc: victim@example.com"],
        'trailing newline' => ["ada@example.com\n"],
        'nul byte' => ["ada@exam\0ple.com"],
        'unicode space' => ["ada@exam\u{00A0}ple.com"],
        'too long for users.email' => [str_repeat('a', 180).'@example.com'],
        'empty' => [''],
        'leading space' => [' ada@example.com'],
        'trailing space' => ['ada@example.com '],
    ]);

    test('a non-string email is rejected', function (mixed $email): void {
        expect(ProfileParser::google(googleInfo(['email' => $email])))->toBeNull();
    })->with([null, 42, true, [['ada@example.com']], 1.5]);
});
