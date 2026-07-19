<?php

use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return response()->json([
        'message' => 'served by jungleforge/php via demo-api',
    ]);
});
