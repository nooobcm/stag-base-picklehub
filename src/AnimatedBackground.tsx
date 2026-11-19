/** Customer-facing ambient pickleball illustrations. */
export default function AnimatedBackground() {
  return (
    <div className="customer-floating-vectors" aria-hidden="true">
      <svg className="floating-vector floating-vector-ball" viewBox="0 0 80 80">
        <circle cx="40" cy="40" r="34" />
        <circle className="vector-ball-hole" cx="28" cy="27" r="2.5" />
        <circle className="vector-ball-hole" cx="45" cy="23" r="2.5" />
        <circle className="vector-ball-hole" cx="55" cy="36" r="2.5" />
        <circle className="vector-ball-hole" cx="29" cy="45" r="2.5" />
        <circle className="vector-ball-hole" cx="45" cy="43" r="2.5" />
        <circle className="vector-ball-hole" cx="38" cy="57" r="2.5" />
      </svg>
      <svg className="floating-vector floating-vector-paddle" viewBox="0 0 100 150">
        <path d="M51 8c-20 0-36 16-36 37 0 17 10 31 25 36l-13 47c-2 7 3 13 10 15l3 1c7 2 14-2 16-9l14-51c15-6 25-20 25-38C95 25 76 8 56 8h-5Z" />
        <path d="M29 43c0-13 9-23 22-25M38 81l31 9" fill="none" stroke="currentColor" strokeWidth="2" />
        <circle className="vector-ball-hole" cx="43" cy="34" r="2" />
        <circle className="vector-ball-hole" cx="58" cy="31" r="2" />
        <circle className="vector-ball-hole" cx="70" cy="41" r="2" />
        <circle className="vector-ball-hole" cx="44" cy="49" r="2" />
        <circle className="vector-ball-hole" cx="60" cy="51" r="2" />
      </svg>
      <svg className="floating-vector floating-vector-court" viewBox="0 0 180 112">
        <rect x="5" y="5" width="170" height="102" rx="8" />
        <path d="M90 5v102M5 31h34v50H5m170-50h-34v50h34M90 31H39v50h51m0-50h51v50H90" />
      </svg>
      <svg className="floating-vector floating-vector-ball-small" viewBox="0 0 60 60">
        <circle cx="30" cy="30" r="24" />
        <circle className="vector-ball-hole" cx="21" cy="21" r="2" />
        <circle className="vector-ball-hole" cx="34" cy="18" r="2" />
        <circle className="vector-ball-hole" cx="40" cy="30" r="2" />
        <circle className="vector-ball-hole" cx="23" cy="35" r="2" />
        <circle className="vector-ball-hole" cx="34" cy="41" r="2" />
      </svg>
      <svg className="floating-vector floating-vector-rally" viewBox="0 0 220 90">
        <path className="rally-path" d="M8 67C49 12 100 18 134 50s51 25 78-19" />
        <circle cx="8" cy="67" r="5" />
        <circle cx="212" cy="31" r="5" />
      </svg>
    </div>
  )
}
