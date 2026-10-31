// ============================================================
// 2-bit variants
// ============================================================

// --- MB2SRLSDFQD : 2× SDFQD, no clear ---
module MB2SRLSDFQD (
    input  wire CP,
    input  wire D1,
    input  wire D2,
    output Q1,
    output Q2,
    input  wire SE,
    input  wire SI
);
    SDFQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .Q(Q1) );
    SDFQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .Q(Q2) );
endmodule

// --- MB2SRLSDFCNQD : 2× SDFKCNQD, sync clear ---
module MB2SRLSDFCNQD (
    input  wire CDN,
    input  wire CP,
    input  wire D1,
    input  wire D2,
    output Q1,
    output Q2,
    input  wire SE,
    input  wire SI
);
    SDFKCNQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .CN(CDN), .Q(Q1) );
    SDFKCNQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .CN(CDN), .Q(Q2) );
endmodule

// --- MB2SRLSDFKCNQD : 2× SDFKCNQD, sync clear (K-timing variant) ---
module MB2SRLSDFKCNQD (
    input  wire CN,
    input  wire CP,
    input  wire D1,
    input  wire D2,
    output Q1,
    output Q2,
    input  wire SE,
    input  wire SI
);
    SDFKCNQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .CN(CN), .Q(Q1) );
    SDFKCNQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .CN(CN), .Q(Q2) );
endmodule

// ============================================================
// 4-bit variants
// ============================================================

// --- MB4SRLSDFQD : 4× SDFQD, no clear ---
module MB4SRLSDFQD (
    input  wire CP,
    input  wire D1,
    input  wire D2,
    input  wire D3,
    input  wire D4,
    output Q1,
    output Q2,
    output Q3,
    output Q4,
    input  wire SE,
    input  wire SI
);
    SDFQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .Q(Q1) );
    SDFQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .Q(Q2) );
    SDFQD u3 ( .SI(Q2), .D(D3), .SE(SE), .CP(CP), .Q(Q3) );
    SDFQD u4 ( .SI(Q3), .D(D4), .SE(SE), .CP(CP), .Q(Q4) );
endmodule

// --- MB4SRLSDFCNQD : 4× SDFKCNQD, sync clear ---
module MB4SRLSDFCNQD (
    input  wire CDN,
    input  wire CP,
    input  wire D1,
    input  wire D2,
    input  wire D3,
    input  wire D4,
    output Q1,
    output Q2,
    output Q3,
    output Q4,
    input  wire SE,
    input  wire SI
);
    SDFKCNQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .CN(CDN), .Q(Q1) );
    SDFKCNQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .CN(CDN), .Q(Q2) );
    SDFKCNQD u3 ( .SI(Q2), .D(D3), .SE(SE), .CP(CP), .CN(CDN), .Q(Q3) );
    SDFKCNQD u4 ( .SI(Q3), .D(D4), .SE(SE), .CP(CP), .CN(CDN), .Q(Q4) );
endmodule

// --- MB4SRLSDFKCNQD : 4× SDFKCNQD, sync clear (K-timing variant) ---
module MB4SRLSDFKCNQD (
    input  wire SI,
    input  wire D1,
    input  wire D2,
    input  wire D3,
    input  wire D4,
    input  wire SE,
    input  wire CP,
    input  wire CN,
    output reg  Q1,
    output reg  Q2,
    output reg  Q3,
    output reg  Q4
);
    SDFKCNQD u1 (.SI(SI), .D(D1), .SE(SE), .CP(CP), .CN(CN), .Q(Q1));
    SDFKCNQD u2 (.SI(Q1), .D(D2), .SE(SE), .CP(CP), .CN(CN), .Q(Q2));
    SDFKCNQD u3 (.SI(Q2), .D(D3), .SE(SE), .CP(CP), .CN(CN), .Q(Q3));
    SDFKCNQD u4 (.SI(Q3), .D(D4), .SE(SE), .CP(CP), .CN(CN), .Q(Q4));
endmodule

// ============================================================
// 2-bit variants with async set (SDN)
// ============================================================

// --- MB2SRLSDFSNQD : 2× SDFSNQD, async set (active-low) ---
module MB2SRLSDFSNQD (
    input  wire CP,
    input  wire D1,
    input  wire D2,
    output Q1,
    output Q2,
    input  wire SDN,
    input  wire SE,
    input  wire SI
);
    SDFSNQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .SDN(SDN), .Q(Q1) );
    SDFSNQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .SDN(SDN), .Q(Q2) );
endmodule

// ============================================================
// 4-bit variants with async set (SDN)
// ============================================================

// --- MB4SRLSDFSNQD : 4× SDFSNQD, async set (active-low) ---
module MB4SRLSDFSNQD (
    input  wire CP,
    input  wire D1,
    input  wire D2,
    input  wire D3,
    input  wire D4,
    output Q1,
    output Q2,
    output Q3,
    output Q4,
    input  wire SDN,
    input  wire SE,
    input  wire SI
);
    SDFSNQD u1 ( .SI(SI), .D(D1), .SE(SE), .CP(CP), .SDN(SDN), .Q(Q1) );
    SDFSNQD u2 ( .SI(Q1), .D(D2), .SE(SE), .CP(CP), .SDN(SDN), .Q(Q2) );
    SDFSNQD u3 ( .SI(Q2), .D(D3), .SE(SE), .CP(CP), .SDN(SDN), .Q(Q3) );
    SDFSNQD u4 ( .SI(Q3), .D(D4), .SE(SE), .CP(CP), .SDN(SDN), .Q(Q4) );
endmodule