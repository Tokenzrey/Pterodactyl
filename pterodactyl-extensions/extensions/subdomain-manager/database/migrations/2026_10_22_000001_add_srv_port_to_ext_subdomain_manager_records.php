<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('ext_subdomain_manager_records', function (Blueprint $table): void {
            // The port the SRV record was made with. A different port later (a mode switch, a changed fixed port)
            // replaces the record (FR-R8). Rows made before this column existed have null here and are replaced once.
            $table->unsignedSmallInteger('srv_port')->nullable()->after('srv_record_id');
        });
    }

    public function down(): void
    {
        Schema::table('ext_subdomain_manager_records', function (Blueprint $table): void {
            $table->dropColumn('srv_port');
        });
    }
};
