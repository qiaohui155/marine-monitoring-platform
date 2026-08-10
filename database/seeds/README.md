# Simulation seed order

The numbered SQL files reproduce the development dataset in this order:

1. Replace the base vessel set with 3,000 realistic clustered and routed positions.
2. Add Oman coastal positions.
3. Replace those Oman positions with the ocean-only model.
4. Add Arabian Sea positions.
5. Replace them with the final sparse offshore model.
6. Replace vessel tracks with the longer Oman track model.
7. Recreate the dynamic `ship_track_lines` view.
8. Create the sea-risk layer baseline.
9. Replace it with the final irregular risk-polygon generation model.
10. Restore the exact current risk, pollution, suspicious-vessel, and warning layers.

Several scripts intentionally use `DELETE` and random simulation functions. Run them
only through the guarded `reset_simulation.ps1` launcher. The real ShipXY AIS collector
is not represented in these seed files.
