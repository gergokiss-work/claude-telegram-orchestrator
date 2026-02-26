(function() {
    try {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "/api/organizations/cc1c9618-cd9a-470b-aab9-8e9976a1dadd/usage", false);
        xhr.send();
        if (xhr.status === 200) {
            return xhr.responseText;
        } else {
            return '{"error":"http_' + xhr.status + '"}';
        }
    } catch(e) {
        return '{"error":"xhr_' + e.name + '"}';
    }
})()
