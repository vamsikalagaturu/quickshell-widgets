pragma Singleton
import QtQuick

QtObject {
    // filesystem path for a Qt.resolvedUrl(), i.e. a file next to the calling QML file
    function local(url) { return String(url).replace(/^file:\/\//, "") }
}
