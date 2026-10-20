<?php

declare(strict_types=1);

namespace SubdomainManager\Models;

use Illuminate\Database\Eloquent\Model;
use SubdomainManager\Support\Labels;

/**
 * What a server wants (domain + label) and what has been made at Cloudflare for it so far (the record ids).
 * Written by the form on save and by RecordSyncer; nothing else touches the ids.
 *
 * @property int $id
 * @property int|null $server_id
 * @property string $server_uuid
 * @property string $domain
 * @property string $label
 * @property string $zone_id
 * @property string|null $synced_name
 * @property string|null $a_record_id
 * @property string|null $srv_record_id
 * @property string $status
 * @property string|null $last_error
 * @property int $attempts
 */
class Record extends Model
{
    public const PENDING = 'pending';

    public const ACTIVE = 'active';

    public const FAILED = 'failed';

    public const DELETING = 'deleting';

    protected $table = 'ext_subdomain_manager_records';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['server_id' => 'integer', 'attempts' => 'integer'];
    }

    /** The host name this row asks for. */
    public function fqdn(): string
    {
        return Labels::fqdn($this->label, $this->domain);
    }

    public function hasCloudflareRecords(): bool
    {
        return $this->a_record_id !== null || $this->srv_record_id !== null;
    }
}
