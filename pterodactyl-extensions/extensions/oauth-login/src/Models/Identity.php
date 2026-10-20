<?php

declare(strict_types=1);

namespace OauthLogin\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Pterodactyl\Models\User;

/**
 * A provider account linked to a Panel user. Only ever written by AccountResolver.
 *
 * @property int $id
 * @property int $user_id
 * @property string $provider
 * @property string $provider_user_id
 */
class Identity extends Model
{
    public const UPDATED_AT = null;

    protected $table = 'ext_oauth_login_identities';

    protected $guarded = [];

    /** @return BelongsTo<User, $this> */
    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }
}
