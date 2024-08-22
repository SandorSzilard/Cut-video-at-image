// data.splice(data.length/2, data.length/2);

console.log(data)

let durationToCutArr = [];

while(data.length > 1) {
let subArr = [];

for(let i = data.length-1; i > 0; i-- ) {
    if(Number(data[i].frame) === Number(data[i-1].frame)+1) {
        subArr.push(data[i]);
    } else {
        subArr.push(data[i]);
        break;
    }
}

durationToCut = (Number(subArr[0].time)+Number(subArr[subArr.length-1].time))/2
durationToCutArr.push(durationToCut)

data.splice(data.length-subArr.length, subArr.length)
}

console.log(durationToCutArr.reverse());

let a = document.createElement('a');
a.href = "data:application/octet-stream,"+encodeURIComponent(durationToCutArr.toString());
a.download = videoName + '_cuts.txt';
a.click();