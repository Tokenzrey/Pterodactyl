<?php

declare(strict_types=1);

namespace MultiNodeSync\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * @property int $id
 * @property int $source_server_id
 * @property string $source_server_uuid
 * @property int $target_node_id
 * @property int $target_allocation_id
 * @property string|null $target_directory
 * @property string $status
 * @property int $progress
 * @property string|null $job_id
 * @property string|null $last_error
 * @property \Carbon\Carbon $created_at
 * @property \Carbon\Carbon $updated_at
 */
class Migration extends Model
{
    public const PENDING = 'pending';

    public const RUNNING = 'running';

    public const COMPLETED = 'completed';

    public const FAILED = 'failed';

    public const CANCELLED = 'cancelled';

    protected $table = 'ext_multi_node_sync_migrations';

    protected $guarded = [];

    /** The values a new migration starts with, in memory as well as in the database. */
    protected $attributes = [
        'status' => self::PENDING,
        'progress' => 0,
    ];

    protected function casts(): array
    {
        return [
            'source_server_id' => 'integer',
            'target_node_id' => 'integer',
            'target_allocation_id' => 'integer',
            'progress' => 'integer',
        ];
    }
}
