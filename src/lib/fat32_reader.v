// FAT32 Read-Only Filesystem Reader
// Finds the first .BMP file in the root directory of a FAT32-formatted SD card,
// then streams its contents byte-by-byte.
//
// Flow:
//   1. Read MBR (block 0) -> find FAT32 partition start LBA
//   2. Read partition boot sector -> get sectors/cluster, FAT start, root cluster
//   3. Scan root directory entries -> find first *.BMP
//   4. Follow FAT cluster chain -> stream file data
//
// Interface:
//   - Directly drives sd_spi block read interface
//   - Outputs file bytes to downstream consumer (bmp_loader)
//
// Limitations:
//   - Read-only, single file
//   - Only searches root directory (no subdirectories)
//   - Only finds .BMP extension (case-insensitive via 8.3 name)
//   - FAT32 only (not FAT12/FAT16)

module fat32_reader (
    input             clk,
    input             rst_n,
    input             start,          // Pulse to begin

    // SD card block read interface (directly drives sd_spi)
    output reg [31:0] sd_block,
    output reg        sd_rd_start,
    input       [7:0] sd_data,
    input             sd_data_valid,
    input             sd_rd_done,
    input             sd_ready,

    // File data output (to bmp_loader)
    output reg  [7:0] file_data,
    output reg        file_data_valid,
    output reg        file_done,       // Entire file has been read

    // Status
    output reg        ready,           // File found, streaming data
    output reg        error,           // Something went wrong
    output reg  [3:0] error_code
);

//==============================================================================
// Error codes
//==============================================================================
localparam ERR_NONE         = 4'd0;
localparam ERR_NO_MBR       = 4'd1;   // MBR signature 0x55AA not found
localparam ERR_NO_FAT32     = 4'd2;   // Partition type not FAT32
localparam ERR_NO_BOOT      = 4'd3;   // Boot sector invalid
localparam ERR_NO_BMP       = 4'd4;   // No .BMP file found in root dir
localparam ERR_SD_FAIL      = 4'd5;   // SD card read error

//==============================================================================
// States
//==============================================================================
localparam S_IDLE            = 5'd0;
localparam S_WAIT_SD         = 5'd1;
localparam S_READ_MBR        = 5'd2;   // Read block 0
localparam S_PARSE_MBR       = 5'd3;
localparam S_READ_BOOT       = 5'd4;   // Read partition boot sector
localparam S_PARSE_BOOT      = 5'd5;
localparam S_READ_ROOTDIR    = 5'd6;   // Read root directory cluster
localparam S_SCAN_DIR        = 5'd7;   // Scan for .BMP entry
localparam S_READ_FAT        = 5'd8;   // Read FAT to follow chain
localparam S_PARSE_FAT       = 5'd9;
localparam S_READ_FILE_BLK   = 5'd10;  // Read file data block
localparam S_STREAM_DATA     = 5'd11;  // Stream bytes out
localparam S_NEXT_SECTOR     = 5'd12;  // Move to next sector in cluster
localparam S_NEXT_CLUSTER    = 5'd13;  // Follow FAT chain
localparam S_DONE            = 5'd14;
localparam S_ERROR           = 5'd15;
localparam S_REQUEST_BLOCK   = 5'd16;  // Request SD block read
localparam S_WAIT_BLOCK      = 5'd17;  // Wait for block data

reg  [4:0]  state;
reg  [4:0]  return_state;    // State to return to after block read

//==============================================================================
// Block buffer (512 bytes in BSRAM)
//==============================================================================
reg  [7:0]  blk_buf [0:511];
reg  [9:0]  blk_wr_idx;     // Write index during SD read
reg  [9:0]  blk_rd_idx;     // Read index during parsing

// Write incoming SD data into buffer
always @(posedge clk) begin
    if (sd_data_valid && state == S_WAIT_BLOCK) begin
        blk_buf[blk_wr_idx[8:0]] <= sd_data;
    end
end

//==============================================================================
// FAT32 parameters (extracted from boot sector)
//==============================================================================
reg  [31:0] part_lba;        // Partition start LBA (from MBR)
reg  [7:0]  sectors_per_cluster;
reg  [15:0] reserved_sectors;
reg  [7:0]  num_fats;
reg  [31:0] fat_size_sectors;
reg  [31:0] root_cluster;    // Root directory first cluster

// Derived values
reg  [31:0] fat_start_lba;   // Absolute LBA of first FAT
reg  [31:0] data_start_lba;  // Absolute LBA of data region (cluster 2)

// File tracking
reg  [31:0] file_cluster;    // Current cluster being read
reg  [31:0] file_size;       // File size in bytes
reg  [31:0] file_bytes_left; // Bytes remaining
reg  [7:0]  sector_in_cluster; // Current sector within cluster (0..sectors_per_cluster-1)
reg  [31:0] dir_cluster;     // Current directory cluster being scanned
reg  [9:0]  dir_entry_idx;   // Current directory entry index in block

// FAT entry offset within sector: (cluster[6:0]) * 4
wire [8:0] fat_entry_off = {file_cluster[6:0], 2'b00};

// Helper: convert cluster number to LBA
// LBA = data_start_lba + (cluster - 2) * sectors_per_cluster
wire [31:0] cluster_to_lba = data_start_lba + ((file_cluster - 32'd2) * {24'd0, sectors_per_cluster});
wire [31:0] dir_cluster_lba = data_start_lba + ((dir_cluster - 32'd2) * {24'd0, sectors_per_cluster});

//==============================================================================
// Helper: read a little-endian 32-bit value from block buffer
//==============================================================================
// We'll read individual bytes and assemble in the state machine

//==============================================================================
// Main State Machine
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        ready <= 0;
        error <= 0;
        error_code <= ERR_NONE;
        file_data_valid <= 0;
        file_done <= 0;
        sd_rd_start <= 0;
        sd_block <= 0;
        blk_wr_idx <= 0;
        blk_rd_idx <= 0;
        part_lba <= 0;
        sectors_per_cluster <= 0;
        reserved_sectors <= 0;
        num_fats <= 0;
        fat_size_sectors <= 0;
        root_cluster <= 0;
        fat_start_lba <= 0;
        data_start_lba <= 0;
        file_cluster <= 0;
        file_size <= 0;
        file_bytes_left <= 0;
        sector_in_cluster <= 0;
        dir_cluster <= 0;
        dir_entry_idx <= 0;
        return_state <= S_IDLE;
    end else begin
        file_data_valid <= 0;
        sd_rd_start <= 0;

        case (state)

            //--------------------------------------------------------------
            S_IDLE: begin
                ready <= 0;
                error <= 0;
                file_done <= 0;
                if (start)
                    state <= S_WAIT_SD;
            end

            //--------------------------------------------------------------
            S_WAIT_SD: begin
                if (sd_ready) begin
                    // Read MBR at block 0
                    sd_block <= 32'd0;
                    return_state <= S_PARSE_MBR;
                    state <= S_REQUEST_BLOCK;
                end
            end

            //--------------------------------------------------------------
            // Generic block read: request block, fill buffer, return
            //--------------------------------------------------------------
            S_REQUEST_BLOCK: begin
                sd_rd_start <= 1;
                blk_wr_idx <= 0;
                state <= S_WAIT_BLOCK;
            end

            S_WAIT_BLOCK: begin
                if (sd_data_valid)
                    blk_wr_idx <= blk_wr_idx + 1;
                if (sd_rd_done) begin
                    blk_rd_idx <= 0;
                    state <= return_state;
                end
            end

            //--------------------------------------------------------------
            // Parse MBR: check signature, get partition 0 start LBA
            //--------------------------------------------------------------
            S_PARSE_MBR: begin
                // Check MBR signature at bytes 510-511: 0x55, 0xAA
                if (blk_buf[510] != 8'h55 || blk_buf[511] != 8'hAA) begin
                    // Maybe this is a "super floppy" format (no MBR, boot sector at block 0)
                    // Check if it looks like a FAT boot sector: byte 0 = 0xEB or 0xE9
                    if (blk_buf[0] == 8'hEB || blk_buf[0] == 8'hE9) begin
                        // No MBR, boot sector is at block 0
                        part_lba <= 32'd0;
                        state <= S_PARSE_BOOT;
                    end else begin
                        error <= 1;
                        error_code <= ERR_NO_MBR;
                        state <= S_ERROR;
                    end
                end else begin
                    // Partition table entry 0 starts at offset 446 (0x1BE)
                    // Partition type at offset 446+4 = 450
                    // Check for FAT32 types: 0x0B (FAT32) or 0x0C (FAT32 LBA)
                    if (blk_buf[450] != 8'h0B && blk_buf[450] != 8'h0C) begin
                        error <= 1;
                        error_code <= ERR_NO_FAT32;
                        state <= S_ERROR;
                    end else begin
                        // Partition start LBA at offset 446+8 = 454, 4 bytes LE
                        part_lba <= {blk_buf[457], blk_buf[456], blk_buf[455], blk_buf[454]};
                        // Read the partition boot sector
                        sd_block <= {blk_buf[457], blk_buf[456], blk_buf[455], blk_buf[454]};
                        return_state <= S_PARSE_BOOT;
                        state <= S_REQUEST_BLOCK;
                    end
                end
            end

            //--------------------------------------------------------------
            // Parse FAT32 Boot Sector
            //--------------------------------------------------------------
            S_PARSE_BOOT: begin
                // Bytes per sector at offset 11-12 (must be 512)
                // We assume 512 and don't check

                // Sectors per cluster at offset 13
                sectors_per_cluster <= blk_buf[13];

                // Reserved sectors at offset 14-15
                reserved_sectors <= {blk_buf[15], blk_buf[14]};

                // Number of FATs at offset 16
                num_fats <= blk_buf[16];

                // FAT size in sectors at offset 36-39 (FAT32 specific)
                fat_size_sectors <= {blk_buf[39], blk_buf[38], blk_buf[37], blk_buf[36]};

                // Root directory cluster at offset 44-47
                root_cluster <= {blk_buf[47], blk_buf[46], blk_buf[45], blk_buf[44]};

                // Calculate derived values
                // FAT start = partition_lba + reserved_sectors
                fat_start_lba <= part_lba + {16'd0, blk_buf[15], blk_buf[14]};

                // Data start = partition_lba + reserved_sectors + (num_fats * fat_size)
                // Usually num_fats = 2
                data_start_lba <= part_lba + {16'd0, blk_buf[15], blk_buf[14]} +
                                  ({24'd0, blk_buf[16]} * {blk_buf[39], blk_buf[38], blk_buf[37], blk_buf[36]});

                // Start scanning root directory
                dir_cluster <= {blk_buf[47], blk_buf[46], blk_buf[45], blk_buf[44]};
                sector_in_cluster <= 0;
                dir_entry_idx <= 0;

                state <= S_READ_ROOTDIR;
            end

            //--------------------------------------------------------------
            // Read root directory sector
            //--------------------------------------------------------------
            S_READ_ROOTDIR: begin
                // Calculate LBA for current sector in directory cluster
                sd_block <= data_start_lba + ((dir_cluster - 32'd2) * {24'd0, sectors_per_cluster})
                           + {24'd0, sector_in_cluster};
                return_state <= S_SCAN_DIR;
                dir_entry_idx <= 0;
                state <= S_REQUEST_BLOCK;
            end

            //--------------------------------------------------------------
            // Scan directory entries (32 bytes each, 16 per sector)
            //--------------------------------------------------------------
            S_SCAN_DIR: begin
                if (dir_entry_idx >= 512) begin
                    // Exhausted this sector, try next in cluster
                    sector_in_cluster <= sector_in_cluster + 1;
                    if (sector_in_cluster + 1 >= sectors_per_cluster) begin
                        // Need to follow directory cluster chain via FAT
                        // For simplicity, assume root dir fits in one cluster
                        // (typical: 8 sectors/cluster * 16 entries/sector = 128 entries)
                        error <= 1;
                        error_code <= ERR_NO_BMP;
                        state <= S_ERROR;
                    end else begin
                        state <= S_READ_ROOTDIR;
                    end
                end else begin
                    // Check current directory entry
                    // Entry starts at dir_entry_idx
                    // Byte 0: first char of filename (0x00 = end, 0xE5 = deleted)
                    // Byte 11: attributes (0x0F = long name entry, skip)
                    if (blk_buf[dir_entry_idx] == 8'h00) begin
                        // End of directory
                        error <= 1;
                        error_code <= ERR_NO_BMP;
                        state <= S_ERROR;
                    end else if (blk_buf[dir_entry_idx] == 8'hE5) begin
                        // Deleted entry, skip
                        dir_entry_idx <= dir_entry_idx + 32;
                    end else if (blk_buf[dir_entry_idx + 11] == 8'h0F) begin
                        // Long filename entry, skip
                        dir_entry_idx <= dir_entry_idx + 32;
                    end else if (blk_buf[dir_entry_idx + 11][4]) begin
                        // Directory bit set, skip (it's a subdirectory)
                        dir_entry_idx <= dir_entry_idx + 32;
                    end else begin
                        // Check extension for "BMP" (8.3 format: name[0:7], ext[8:10])
                        // Extension is at offset 8,9,10 in the entry
                        if ((blk_buf[dir_entry_idx + 8] == 8'h42) &&   // 'B'
                            (blk_buf[dir_entry_idx + 9] == 8'h4D) &&   // 'M'
                            (blk_buf[dir_entry_idx + 10] == 8'h50)) begin // 'P'
                            // Found a .BMP file!
                            // Get starting cluster (high word at 20-21, low word at 26-27)
                            file_cluster <= {blk_buf[dir_entry_idx + 21],
                                            blk_buf[dir_entry_idx + 20],
                                            blk_buf[dir_entry_idx + 27],
                                            blk_buf[dir_entry_idx + 26]};
                            // File size at offset 28-31
                            file_size <= {blk_buf[dir_entry_idx + 31],
                                         blk_buf[dir_entry_idx + 30],
                                         blk_buf[dir_entry_idx + 29],
                                         blk_buf[dir_entry_idx + 28]};
                            file_bytes_left <= {blk_buf[dir_entry_idx + 31],
                                              blk_buf[dir_entry_idx + 30],
                                              blk_buf[dir_entry_idx + 29],
                                              blk_buf[dir_entry_idx + 28]};
                            sector_in_cluster <= 0;
                            ready <= 1;
                            state <= S_READ_FILE_BLK;
                        end else begin
                            // Not a BMP, check next entry
                            dir_entry_idx <= dir_entry_idx + 32;
                        end
                    end
                end
            end

            //--------------------------------------------------------------
            // Read a file data sector
            //--------------------------------------------------------------
            S_READ_FILE_BLK: begin
                sd_block <= data_start_lba + ((file_cluster - 32'd2) * {24'd0, sectors_per_cluster})
                           + {24'd0, sector_in_cluster};
                return_state <= S_STREAM_DATA;
                state <= S_REQUEST_BLOCK;
            end

            //--------------------------------------------------------------
            // Stream block buffer bytes to output
            //--------------------------------------------------------------
            S_STREAM_DATA: begin
                if (file_bytes_left == 0 || blk_rd_idx >= 512) begin
                    if (file_bytes_left == 0) begin
                        file_done <= 1;
                        state <= S_DONE;
                    end else begin
                        // Move to next sector
                        state <= S_NEXT_SECTOR;
                    end
                end else begin
                    file_data <= blk_buf[blk_rd_idx[8:0]];
                    file_data_valid <= 1;
                    blk_rd_idx <= blk_rd_idx + 1;
                    file_bytes_left <= file_bytes_left - 1;
                end
            end

            //--------------------------------------------------------------
            // Advance to next sector in cluster or next cluster
            //--------------------------------------------------------------
            S_NEXT_SECTOR: begin
                sector_in_cluster <= sector_in_cluster + 1;
                if (sector_in_cluster + 1 >= sectors_per_cluster) begin
                    // End of cluster, follow FAT chain
                    state <= S_NEXT_CLUSTER;
                end else begin
                    state <= S_READ_FILE_BLK;
                end
            end

            //--------------------------------------------------------------
            // Follow FAT chain to next cluster
            //--------------------------------------------------------------
            S_NEXT_CLUSTER: begin
                // Each FAT entry is 4 bytes. 128 entries per 512-byte sector.
                // FAT sector = fat_start_lba + (cluster * 4) / 512
                //            = fat_start_lba + cluster / 128
                // Offset within sector = (cluster % 128) * 4
                sd_block <= fat_start_lba + (file_cluster >> 7);
                return_state <= S_PARSE_FAT;
                state <= S_REQUEST_BLOCK;
            end

            //--------------------------------------------------------------
            // Parse FAT entry to get next cluster
            //--------------------------------------------------------------
            S_PARSE_FAT: begin
                // fat_offset = file_cluster[6:0] * 4 = {file_cluster[6:0], 2'b00}
                // Read 4 bytes LE from blk_buf at that offset
                file_cluster <= {blk_buf[fat_entry_off + 3] & 8'h0F,
                                blk_buf[fat_entry_off + 2],
                                blk_buf[fat_entry_off + 1],
                                blk_buf[fat_entry_off + 0]};

                // Check for end-of-chain (0x0FFFFFF8 to 0x0FFFFFFF)
                if ({blk_buf[fat_entry_off + 3] & 8'h0F, blk_buf[fat_entry_off + 2]} >= 16'h0FFF &&
                    blk_buf[fat_entry_off + 1] == 8'hFF &&
                    blk_buf[fat_entry_off + 0] >= 8'hF8) begin
                    file_done <= 1;
                    state <= S_DONE;
                end else begin
                    sector_in_cluster <= 0;
                    state <= S_READ_FILE_BLK;
                end
            end

            //--------------------------------------------------------------
            S_DONE: begin
                file_done <= 1;
            end

            S_ERROR: begin
                error <= 1;
            end

        endcase
    end
end

endmodule
