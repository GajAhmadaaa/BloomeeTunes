import 'package:flutter_bloc/flutter_bloc.dart';

/// Manages the visibility state of the full-screen player overlay.
class PlayerOverlayCubit extends Cubit<bool> {
  PlayerOverlayCubit() : super(false);

  /// Callback to collapse the UpNext panel, returns true if panel was expanded
  bool Function()? _collapseUpNextPanel;

  /// Register a callback to collapse the UpNext panel
  void registerUpNextPanelCollapse(bool Function() collapse) {
    _collapseUpNextPanel = collapse;
  }

  /// Unregister the UpNext panel collapse callback
  void unregisterUpNextPanelCollapse() {
    _collapseUpNextPanel = null;
  }

  /// Try to collapse the UpNext panel if it's expanded
  /// Returns true if the panel was collapsed, false otherwise
  bool collapseUpNextPanel() {
    return _collapseUpNextPanel?.call() ?? false;
  }

  /// Callback to check if the player is visually visible (including during
  /// the open/close animation), even if the cubit state already flipped.
  bool Function()? _playerVisibilityCheck;

  /// Register a callback that reports visual player visibility
  void registerPlayerVisibilityCheck(bool Function() check) {
    _playerVisibilityCheck = check;
  }

  /// Unregister the player visibility callback
  void unregisterPlayerVisibilityCheck() {
    _playerVisibilityCheck = null;
  }

  /// True if the player is on screen or mid-animation (closing).
  /// Used by back handling so a back press during the close animation
  /// is swallowed instead of falling through to app exit.
  bool isPlayerVisuallyVisible() {
    return state || (_playerVisibilityCheck?.call() ?? false);
  }

  void showPlayer() => emit(true);

  void hidePlayer() => emit(false);

  void togglePlayer() => emit(!state);

  bool get isPlayerVisible => state;
}
